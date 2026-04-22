-- =============================================================================
-- Almost App — Crossed Paths Matching Algorithm
-- Generated: 2026-04-21
-- =============================================================================
-- This migration does three things:
--   1. Converts connection_type from a single enum to an enum array on both
--      trips and trip_overlaps (PDF specifies multiselect intent).
--   2. Adds the matching RPC: compute_overlaps_for_trip_v1(p_trip_id).
--   3. Adds a trigger on trips that calls the RPC on insert / relevant update.
--
-- Matching rule:
--   Two trips match when they share (airport, date) in any of their 3 slots
--   AND their intent arrays overlap AND both owners have complete profiles
--   AND neither user has blocked the other.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. CONVERT connection_type COLUMNS TO ARRAY
-- =============================================================================
-- Existing single-value rows are wrapped into 1-element arrays by USING clause.
-- No data loss. Array overlap operator (&&) behaves identically on 1-element
-- arrays, so this is backward compatible with any existing logic.

ALTER TABLE public.trips
  ALTER COLUMN connection_type TYPE public.connection_type[]
  USING ARRAY[connection_type];

ALTER TABLE public.trip_overlaps
  ALTER COLUMN connection_type TYPE public.connection_type[]
  USING ARRAY[connection_type];


-- =============================================================================
-- 2. MATCHING RPC
-- =============================================================================
-- compute_overlaps_for_trip_v1(p_trip_id uuid)
--
-- Single source of truth for the matching logic. Called by the trips trigger
-- on every INSERT and on every UPDATE that touches a match-relevant field.
--
-- Behavior:
--   a. If the trip is soft-deleted -> soft-delete all overlaps touching it. Stop.
--   b. If the trip owner's profile_complete = false -> stop (no matching yet).
--   c. Otherwise: soft-delete prior overlaps for this trip, then recompute by
--      scanning every other active trip and inserting fresh overlap rows.
--
-- Running in SECURITY DEFINER because trip_overlaps has an RLS policy that
-- blocks user-level inserts. `SET search_path = ''` is required for safety.

CREATE OR REPLACE FUNCTION public.compute_overlaps_for_trip_v1(p_trip_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_trip            public.trips%ROWTYPE;
  v_owner_complete  boolean;
BEGIN
  -- Load the trip. If it no longer exists, exit quietly.
  SELECT *
  INTO v_trip
  FROM public.trips
  WHERE id = p_trip_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Soft-delete path: trip was just soft-deleted. Clear its overlaps and stop.
  IF v_trip.deleted_at IS NOT NULL THEN
    UPDATE public.trip_overlaps
       SET deleted_at = now()
     WHERE (trip_a_id = p_trip_id OR trip_b_id = p_trip_id)
       AND deleted_at IS NULL;
    RETURN;
  END IF;

  -- Gate: owner must have a complete profile to participate in matching.
  SELECT p.profile_complete
    INTO v_owner_complete
    FROM public.profiles p
   WHERE p.id = v_trip.created_by
     AND p.deleted_at IS NULL;

  IF NOT COALESCE(v_owner_complete, false) THEN
    RETURN;
  END IF;

  -- Clean slate: soft-delete any existing overlaps for this trip before
  -- recomputing. This keeps the algorithm simple and idempotent.
  UPDATE public.trip_overlaps
     SET deleted_at = now()
   WHERE (trip_a_id = p_trip_id OR trip_b_id = p_trip_id)
     AND deleted_at IS NULL;

  -- Compute and insert overlaps.
  -- Build T's (airport, date) slots as a virtual table, then join against
  -- every other active trip whose intent array overlaps T's.
  INSERT INTO public.trip_overlaps (
    user_a_id,
    user_b_id,
    trip_a_id,
    trip_b_id,
    matched_airport_id,
    overlap_date,
    connection_type
  )
  SELECT
    LEAST(v_trip.created_by, c.created_by)                                       AS user_a_id,
    GREATEST(v_trip.created_by, c.created_by)                                    AS user_b_id,
    CASE WHEN v_trip.created_by < c.created_by THEN v_trip.id ELSE c.id END      AS trip_a_id,
    CASE WHEN v_trip.created_by < c.created_by THEN c.id      ELSE v_trip.id END AS trip_b_id,
    t_slot.airport_id                                                            AS matched_airport_id,
    t_slot.slot_date                                                             AS overlap_date,
    -- Intersection of intent arrays (only the shared intents go in the row).
    ARRAY(
      SELECT x
        FROM unnest(v_trip.connection_type) AS x
       WHERE x = ANY (c.connection_type)
    )::public.connection_type[]                                                  AS connection_type
  FROM (
    -- T's three slots. Filter out layover if either side is NULL.
    VALUES
      (v_trip.departure_airport_id, v_trip.departure_date),
      (v_trip.layover_airport_id,   v_trip.layover_date),
      (v_trip.arrival_airport_id,   v_trip.arrival_date)
  ) AS t_slot(airport_id, slot_date)
  JOIN public.trips c
    ON  c.id          <> v_trip.id
    AND c.created_by  <> v_trip.created_by
    AND c.deleted_at  IS NULL
    AND c.connection_type && v_trip.connection_type
    AND (
         (c.departure_airport_id = t_slot.airport_id AND c.departure_date = t_slot.slot_date)
      OR (c.layover_airport_id   = t_slot.airport_id AND c.layover_date   = t_slot.slot_date)
      OR (c.arrival_airport_id   = t_slot.airport_id AND c.arrival_date   = t_slot.slot_date)
    )
  WHERE t_slot.airport_id IS NOT NULL
    AND t_slot.slot_date  IS NOT NULL
    -- C's owner must have a complete, active profile.
    AND EXISTS (
      SELECT 1
        FROM public.profiles p
       WHERE p.id                = c.created_by
         AND p.profile_complete  = true
         AND p.deleted_at        IS NULL
    )
    -- No block in either direction.
    AND NOT EXISTS (
      SELECT 1
        FROM public.user_blocks ub
       WHERE (ub.created_by = v_trip.created_by AND ub.blocked_user_id = c.created_by)
          OR (ub.created_by = c.created_by     AND ub.blocked_user_id = v_trip.created_by)
    )
  ON CONFLICT (trip_a_id, trip_b_id, matched_airport_id, overlap_date) DO NOTHING;
END;
$$;

-- Lock the RPC down. It is meant to be called by the trigger (which runs as
-- the Postgres owner via SECURITY DEFINER). No client-side caller should hit it.
REVOKE EXECUTE ON FUNCTION public.compute_overlaps_for_trip_v1(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.compute_overlaps_for_trip_v1(uuid) FROM anon, authenticated;


-- =============================================================================
-- 3. TRIGGER: trips -> compute overlaps
-- =============================================================================
-- Trigger function is a thin wrapper around the RPC. Future algorithm changes
-- only touch the RPC; the trigger stays as-is.

CREATE OR REPLACE FUNCTION public.trg_fn_compute_trip_overlaps()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public.compute_overlaps_for_trip_v1(NEW.id);
  RETURN NEW;
END;
$$;

-- Fires on every insert (fresh trip -> compute matches).
DROP TRIGGER IF EXISTS trg_compute_overlaps_on_trip_insert ON public.trips;
CREATE TRIGGER trg_compute_overlaps_on_trip_insert
  AFTER INSERT ON public.trips
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_fn_compute_trip_overlaps();

-- Fires on update only when a match-relevant field actually changed.
-- Using IS DISTINCT FROM to correctly handle NULL transitions (layover fields
-- and deleted_at).
DROP TRIGGER IF EXISTS trg_compute_overlaps_on_trip_update ON public.trips;
CREATE TRIGGER trg_compute_overlaps_on_trip_update
  AFTER UPDATE ON public.trips
  FOR EACH ROW
  WHEN (
       OLD.departure_airport_id IS DISTINCT FROM NEW.departure_airport_id
    OR OLD.departure_date       IS DISTINCT FROM NEW.departure_date
    OR OLD.layover_airport_id   IS DISTINCT FROM NEW.layover_airport_id
    OR OLD.layover_date         IS DISTINCT FROM NEW.layover_date
    OR OLD.arrival_airport_id   IS DISTINCT FROM NEW.arrival_airport_id
    OR OLD.arrival_date         IS DISTINCT FROM NEW.arrival_date
    OR OLD.connection_type      IS DISTINCT FROM NEW.connection_type
    OR OLD.deleted_at           IS DISTINCT FROM NEW.deleted_at
  )
  EXECUTE FUNCTION public.trg_fn_compute_trip_overlaps();


COMMIT;
