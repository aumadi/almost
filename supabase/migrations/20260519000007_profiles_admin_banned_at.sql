-- =============================================================================
-- Almost App — Admin-ban infrastructure (user-side enforcement only)
-- Generated: 2026-05-19
-- =============================================================================
-- Adds the canonical "is this user admin-banned" flag to profiles and wires
-- it into every user-facing surface so that the moment admin_banned_at is
-- set on a profile, that user becomes invisible to other users across the
-- whole app:
--
--   • Other users' Crossed Paths, Trips overlap preview, Chat list, Chat
--     detail, Notifications — all filter banned profiles automatically
--     because they JOIN public.profiles under security_invoker + the new
--     RLS gate.
--   • The matching algorithm no longer creates new overlaps with or for a
--     banned user.
--   • Banned users (and other users) cannot insert messages into a chat
--     that involves a banned participant.
--   • Direct profile lookups by id return nothing.
--
-- This migration intentionally does NOT add the admin-side RPCs or admin
-- read views — those live in a separate migration when the admin panel is
-- built. Admin tooling will use SECURITY DEFINER RPCs that bypass these
-- gates so admins still see banned users.
--
-- Storage choice:
--   timestamptz, NULL = not banned, value = banned-at moment. Gives an
--   audit timestamp for free and matches the existing deleted_at pattern.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Add the column
-- =============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS admin_banned_at timestamptz;

-- Index for admin queries ("show me all banned users") and for the gate
-- checks inside views/RLS. Partial index keeps it tiny — only banned rows.
CREATE INDEX IF NOT EXISTS idx_profiles_admin_banned_at
  ON public.profiles(admin_banned_at DESC)
  WHERE admin_banned_at IS NOT NULL;


-- =============================================================================
-- 2. profiles_select_all RLS — hide banned profiles from regular users
-- =============================================================================
-- Layered on top of the existing deleted_at + user_blocks gates added in
-- 20260519000002. Admin RPCs (SECURITY DEFINER, future migration) bypass
-- this entirely.

DROP POLICY IF EXISTS profiles_select_all ON public.profiles;

CREATE POLICY profiles_select_all
  ON public.profiles FOR SELECT
  USING (
    deleted_at      IS NULL
    AND admin_banned_at IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
       WHERE (ub.created_by = auth.uid()  AND ub.blocked_user_id = profiles.id)
          OR (ub.created_by = profiles.id AND ub.blocked_user_id = auth.uid())
    )
  );


-- =============================================================================
-- 3. messages_insert_own RLS — reject if either side of the chat is banned
-- =============================================================================
-- Builds on the existing chat-membership + user_blocks guards from
-- 20260519000002. A banned user trying to send fails; an unbanned user
-- trying to message a banned participant also fails.

DROP POLICY IF EXISTS messages_insert_own ON public.messages;

CREATE POLICY messages_insert_own
  ON public.messages FOR INSERT
  WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1
        FROM public.chats c
       WHERE c.id          = chat_id
         AND c.deleted_at  IS NULL
         AND (c.user_a_id = auth.uid() OR c.user_b_id = auth.uid())
         AND NOT EXISTS (
           SELECT 1 FROM public.user_blocks ub
            WHERE (ub.created_by = c.user_a_id AND ub.blocked_user_id = c.user_b_id)
               OR (ub.created_by = c.user_b_id AND ub.blocked_user_id = c.user_a_id)
         )
         AND NOT EXISTS (
           SELECT 1 FROM public.profiles p
            WHERE p.id IN (c.user_a_id, c.user_b_id)
              AND p.admin_banned_at IS NOT NULL
         )
    )
  );


-- =============================================================================
-- 4. Matching algorithm — skip banned owner and banned candidates
-- =============================================================================
-- compute_overlaps_for_trip_v2 already gates on profile_complete +
-- deleted_at. Banned users get the same treatment: function returns early
-- if the trip's owner is banned; the candidate EXISTS check rejects
-- candidates whose profile is banned. Net effect:
--   • Banned user adds/edits a trip → no overlaps created for them.
--   • Other user adds/edits a trip → banned candidates are skipped.
--   • Existing trip_overlaps rows are NOT auto-purged — the views' joins
--     to profiles (under RLS) already hide them from every consumer, so
--     they're harmless until next recompute clears them.

CREATE OR REPLACE FUNCTION public.compute_overlaps_for_trip_v2(p_trip_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_trip            public.trips%ROWTYPE;
  v_owner_complete  boolean;
  v_owner_banned    boolean;
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

  -- Gate: owner must have a complete, non-deleted, non-banned profile.
  SELECT p.profile_complete,
         (p.admin_banned_at IS NOT NULL)
    INTO v_owner_complete, v_owner_banned
    FROM public.profiles p
   WHERE p.id          = v_trip.created_by
     AND p.deleted_at  IS NULL;

  IF NOT COALESCE(v_owner_complete, false) OR COALESCE(v_owner_banned, true) THEN
    RETURN;
  END IF;

  -- =====================================================================
  -- Single statement with data-modifying CTEs (unchanged structure from v2;
  -- only the candidate profile EXISTS check gains an admin_banned_at gate).
  -- =====================================================================
  WITH
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
             AND candidate_profile.admin_banned_at  IS NULL    -- NEW: skip banned candidates
        )
        AND NOT EXISTS (
          SELECT 1
            FROM public.user_blocks existing_block
           WHERE (existing_block.created_by      = v_trip.created_by         AND existing_block.blocked_user_id = candidate_trip.created_by)
              OR (existing_block.created_by      = candidate_trip.created_by AND existing_block.blocked_user_id = v_trip.created_by)
        )
    ),

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


COMMIT;
