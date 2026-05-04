-- =============================================================================
-- Almost App — Matching algorithm v2: diff and reuse
-- Generated: 2026-04-29
-- =============================================================================
-- Replaces the v1 "clean slate then recompute" approach with a smarter
-- diff-based pass that only touches what actually changed:
--
--   • Soft-delete only existing active overlaps that are no longer valid.
--   • Reactivate soft-deleted overlaps that should now exist again
--     (e.g. user re-added a layover that was previously matched).
--   • Update connection_type on still-active overlaps if the intent
--     intersection changed.
--   • Insert truly new overlaps (no row exists yet, neither active nor
--     soft-deleted, for this natural key).
--
-- Result: editing a trip in a way that does NOT affect a particular
-- overlap leaves that overlap untouched — original created_at, original
-- id, no spurious deleted_at timestamp.
--
-- v1 is preserved (not dropped) so it can be called manually for one-off
-- testing / forced recomputes. The trigger function is updated to call v2.
-- =============================================================================


-- =============================================================================
-- 1. compute_overlaps_for_trip_v2
-- =============================================================================

CREATE OR REPLACE FUNCTION public.compute_overlaps_for_trip_v2(p_trip_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_trip            public.trips%ROWTYPE;
  v_owner_complete  boolean;
BEGIN
  -- Load the trip. Exit quietly if it no longer exists.
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
   WHERE p.id           = v_trip.created_by
     AND p.deleted_at  IS NULL;

  IF NOT COALESCE(v_owner_complete, false) THEN
    RETURN;
  END IF;

  -- =====================================================================
  -- Single statement with data-modifying CTEs.
  -- All four operations see the same snapshot, so they target disjoint
  -- rows and can run atomically.
  -- =====================================================================
  WITH
    -- The set of overlaps that SHOULD exist given the trip's current state.
    should_exist AS (
      SELECT
        LEAST(v_trip.created_by, candidate_trip.created_by)                                   AS user_a_id,
        GREATEST(v_trip.created_by, candidate_trip.created_by)                                AS user_b_id,
        CASE WHEN v_trip.created_by < candidate_trip.created_by
             THEN v_trip.id ELSE candidate_trip.id
        END                                                                                   AS trip_a_id,
        CASE WHEN v_trip.created_by < candidate_trip.created_by
             THEN candidate_trip.id ELSE v_trip.id
        END                                                                                   AS trip_b_id,
        my_slot.airport_id                                                                    AS matched_airport_id,
        my_slot.slot_date                                                                     AS overlap_date,
        ARRAY(
          SELECT intent
            FROM unnest(v_trip.connection_type) AS intent
           WHERE intent = ANY (candidate_trip.connection_type)
        )::public.connection_type[]                                                           AS connection_type
      FROM (
        VALUES
          (v_trip.departure_airport_id, v_trip.departure_date),
          (v_trip.layover_airport_id,   v_trip.layover_date),
          (v_trip.arrival_airport_id,   v_trip.arrival_date)
      ) AS my_slot(airport_id, slot_date)
      JOIN public.trips candidate_trip
        ON  candidate_trip.id          <> v_trip.id
        AND candidate_trip.created_by  <> v_trip.created_by
        AND candidate_trip.deleted_at  IS NULL
        AND candidate_trip.connection_type && v_trip.connection_type
        AND (
             (candidate_trip.departure_airport_id = my_slot.airport_id AND candidate_trip.departure_date = my_slot.slot_date)
          OR (candidate_trip.layover_airport_id   = my_slot.airport_id AND candidate_trip.layover_date   = my_slot.slot_date)
          OR (candidate_trip.arrival_airport_id   = my_slot.airport_id AND candidate_trip.arrival_date   = my_slot.slot_date)
        )
      WHERE my_slot.airport_id IS NOT NULL
        AND my_slot.slot_date  IS NOT NULL
        AND EXISTS (
          SELECT 1
            FROM public.profiles candidate_profile
           WHERE candidate_profile.id               = candidate_trip.created_by
             AND candidate_profile.profile_complete = true
             AND candidate_profile.deleted_at       IS NULL
        )
        AND NOT EXISTS (
          SELECT 1
            FROM public.user_blocks existing_block
           WHERE (existing_block.created_by      = v_trip.created_by         AND existing_block.blocked_user_id = candidate_trip.created_by)
              OR (existing_block.created_by      = candidate_trip.created_by AND existing_block.blocked_user_id = v_trip.created_by)
        )
    ),

    -- Step 1: soft-delete active overlaps that no longer match.
    soft_deleted AS (
      UPDATE public.trip_overlaps existing_overlap
         SET deleted_at = now()
       WHERE (existing_overlap.trip_a_id = p_trip_id OR existing_overlap.trip_b_id = p_trip_id)
         AND existing_overlap.deleted_at IS NULL
         AND NOT EXISTS (
           SELECT 1 FROM should_exist se
            WHERE se.trip_a_id          = existing_overlap.trip_a_id
              AND se.trip_b_id          = existing_overlap.trip_b_id
              AND se.matched_airport_id = existing_overlap.matched_airport_id
              AND se.overlap_date       = existing_overlap.overlap_date
         )
      RETURNING existing_overlap.id
    ),

    -- Step 2: reactivate previously soft-deleted overlaps that should exist again.
    --         Also refresh connection_type in case the intersection changed.
    reactivated AS (
      UPDATE public.trip_overlaps existing_overlap
         SET deleted_at      = NULL,
             connection_type = se.connection_type
        FROM should_exist se
       WHERE (existing_overlap.trip_a_id = p_trip_id OR existing_overlap.trip_b_id = p_trip_id)
         AND existing_overlap.deleted_at IS NOT NULL
         AND se.trip_a_id          = existing_overlap.trip_a_id
         AND se.trip_b_id          = existing_overlap.trip_b_id
         AND se.matched_airport_id = existing_overlap.matched_airport_id
         AND se.overlap_date       = existing_overlap.overlap_date
      RETURNING existing_overlap.id
    ),

    -- Step 3: update connection_type on still-active overlaps if the
    --         intent intersection changed (without reactivation needed).
    intent_refreshed AS (
      UPDATE public.trip_overlaps existing_overlap
         SET connection_type = se.connection_type
        FROM should_exist se
       WHERE (existing_overlap.trip_a_id = p_trip_id OR existing_overlap.trip_b_id = p_trip_id)
         AND existing_overlap.deleted_at IS NULL
         AND se.trip_a_id          = existing_overlap.trip_a_id
         AND se.trip_b_id          = existing_overlap.trip_b_id
         AND se.matched_airport_id = existing_overlap.matched_airport_id
         AND se.overlap_date       = existing_overlap.overlap_date
         AND existing_overlap.connection_type IS DISTINCT FROM se.connection_type
      RETURNING existing_overlap.id
    )

  -- Step 4: insert overlaps that have no row at all (active or soft-deleted)
  --         for this natural key. Snapshot semantics ensure we don't try to
  --         re-insert a key that's about to be reactivated.
  INSERT INTO public.trip_overlaps (
    user_a_id, user_b_id, trip_a_id, trip_b_id,
    matched_airport_id, overlap_date, connection_type
  )
  SELECT
    se.user_a_id,
    se.user_b_id,
    se.trip_a_id,
    se.trip_b_id,
    se.matched_airport_id,
    se.overlap_date,
    se.connection_type
    FROM should_exist se
   WHERE NOT EXISTS (
     SELECT 1
       FROM public.trip_overlaps existing_overlap
      WHERE existing_overlap.trip_a_id          = se.trip_a_id
        AND existing_overlap.trip_b_id          = se.trip_b_id
        AND existing_overlap.matched_airport_id = se.matched_airport_id
        AND existing_overlap.overlap_date       = se.overlap_date
   )
  ON CONFLICT (trip_a_id, trip_b_id, matched_airport_id, overlap_date) DO NOTHING;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.compute_overlaps_for_trip_v2(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.compute_overlaps_for_trip_v2(uuid) FROM anon, authenticated;


-- =============================================================================
-- 2. Switch the trigger function to call v2
-- =============================================================================
-- The trigger itself stays the same. We only update what the wrapper calls.
-- v1 remains in the database for one-off manual recomputes.

CREATE OR REPLACE FUNCTION public.trg_fn_compute_trip_overlaps()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public.compute_overlaps_for_trip_v2(NEW.id);
  RETURN NEW;
END;
$$;
