-- =============================================================================
-- Almost App — Symmetric block + declined-consistency on Trips preview
-- Generated: 2026-05-19
-- =============================================================================
-- Two related changes shipped together:
--
-- 1. DECLINE CONSISTENCY (bug fix)
--    visible_crossed_paths hides cards on the decliner's side when they
--    declined a request from the other user. visible_my_trips' avatar
--    preview did NOT mirror this — so the photo still leaked into the
--    OVERLAPS: strip on the Trips screen. This migration adds the same
--    declined filter to overlap_users_preview.
--
-- 2. SYMMETRIC BLOCK (new feature, per Feature Overview doc — "Safety
--    Tools / Block hides the profiles from each other")
--    The view layer already filters blocked pairs:
--      • visible_crossed_paths        ✔ (existing user_blocks filter)
--      • visible_my_trips preview     ✔ (existing user_blocks filter)
--      • visible_my_chats             ✔ (existing user_blocks filter)
--      • visible_chat_detail          ✔ (existing user_blocks filter)
--    What's missing is enforcement at write time and on the raw profile
--    table reads, so blocked users can still POST messages and can still
--    read the blocker's profile directly. This migration:
--      • adds a user_blocks guard to messages_insert_own RLS
--      • adds a user_blocks guard to profiles_select_all RLS
--      • adds block_user() and unblock_user() RPCs as the single
--        FlutterFlow entry points
--
-- Net effect after deploy:
--   When A blocks B (or vice versa):
--     - Neither sees the other anywhere (already true in all four views)
--     - Neither can read the other's profile directly (new — profiles RLS)
--     - Neither can send a message to the other (new — messages RLS)
--   = symmetric and silent, matching the doc.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Recreate visible_my_trips — add decliner filter to overlap_users_preview
-- =============================================================================
-- Only change vs the previous version (20260429000000): an additional
-- NOT EXISTS clause inside the visible_other_users CTE that excludes any
-- "other user" the CURRENT viewer has declined.

DROP VIEW IF EXISTS public.visible_my_trips;

CREATE VIEW public.visible_my_trips AS
SELECT
  -- Trip identity (2)
  trip.id            AS trip_id,
  trip.created_at    AS created_at,

  -- Dates (3)
  trip.departure_date,
  trip.layover_date,
  trip.arrival_date,

  -- Intents (1)
  trip.connection_type AS intents,

  -- Departure airport (3 — uuid + iata + city)
  departure_airport.id        AS departure_airport_id,
  departure_airport.iata_code AS departure_iata,
  departure_airport.city      AS departure_city,

  -- Layover airport — nullable (3 — uuid + iata + city)
  layover_airport.id          AS layover_airport_id,
  layover_airport.iata_code   AS layover_iata,
  layover_airport.city        AS layover_city,

  -- Arrival airport (3 — uuid + iata + city)
  arrival_airport.id          AS arrival_airport_id,
  arrival_airport.iata_code   AS arrival_iata,
  arrival_airport.city        AS arrival_city,

  -- Layover convenience flag (1)
  (trip.layover_airport_id IS NOT NULL) AS has_layover,

  -- Overlap summary (2)
  overlap_summary.total_count AS overlap_count,
  overlap_summary.preview     AS overlap_users_preview

FROM public.trips trip

JOIN public.airports departure_airport
  ON departure_airport.id = trip.departure_airport_id

LEFT JOIN public.airports layover_airport
  ON layover_airport.id = trip.layover_airport_id

JOIN public.airports arrival_airport
  ON arrival_airport.id = trip.arrival_airport_id

LEFT JOIN LATERAL (
  WITH distinct_other_users AS (
    SELECT
      CASE WHEN overlap.user_a_id = trip.created_by
           THEN overlap.user_b_id
           ELSE overlap.user_a_id
      END                      AS other_user_id,
      MAX(overlap.created_at)  AS latest_overlap
    FROM public.trip_overlaps overlap
    WHERE (overlap.trip_a_id = trip.id OR overlap.trip_b_id = trip.id)
      AND overlap.deleted_at IS NULL
    GROUP BY
      CASE WHEN overlap.user_a_id = trip.created_by
           THEN overlap.user_b_id
           ELSE overlap.user_a_id
      END
  ),
  visible_other_users AS (
    SELECT
      du.other_user_id,
      du.latest_overlap,
      other_profile.first_name,
      other_photo.storage_path AS photo_path
    FROM distinct_other_users du
    JOIN public.profiles other_profile
      ON other_profile.id         = du.other_user_id
      AND other_profile.deleted_at IS NULL
    LEFT JOIN public.profile_photos other_photo
      ON other_photo.profile_id    = du.other_user_id
      AND other_photo.display_order = 1
      AND other_photo.deleted_at   IS NULL
    -- Existing: hide blocked pairs (either direction).
    WHERE NOT EXISTS (
      SELECT 1 FROM public.user_blocks existing_block
      WHERE (existing_block.created_by      = auth.uid()       AND existing_block.blocked_user_id = du.other_user_id)
         OR (existing_block.blocked_user_id = auth.uid()       AND existing_block.created_by      = du.other_user_id)
    )
    -- NEW: hide users the current viewer has DECLINED. Mirrors the same
    -- filter on visible_crossed_paths so the Trips avatar strip stays in
    -- sync with the Crossed Paths grid.
    AND NOT EXISTS (
      SELECT 1 FROM public.connection_requests declined_req
      WHERE declined_req.deleted_at   IS NULL
        AND declined_req.status       = 'declined'
        AND declined_req.recipient_id = auth.uid()
        AND declined_req.created_by   = du.other_user_id
    )
  )
  SELECT
    COUNT(*)::int AS total_count,
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'user_id',    top_user.other_user_id,
            'first_name', top_user.first_name,
            'photo_path', top_user.photo_path
          )
          ORDER BY top_user.latest_overlap DESC
        )
        FROM (
          SELECT *
          FROM visible_other_users
          ORDER BY latest_overlap DESC
          LIMIT 5
        ) top_user
      ),
      '[]'::jsonb
    ) AS preview
  FROM visible_other_users
) overlap_summary ON TRUE

WHERE trip.created_by  = auth.uid()
  AND trip.deleted_at IS NULL;

ALTER VIEW public.visible_my_trips SET (security_invoker = true);
GRANT SELECT ON public.visible_my_trips TO authenticated;


-- =============================================================================
-- 2. Update messages_insert_own RLS — block-aware
-- =============================================================================
-- Previously: caller could insert messages into any chat they participate
-- in. Now: also rejects inserts when a user_blocks row exists in either
-- direction between the caller and the OTHER chat participant.

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
    )
  );


-- =============================================================================
-- 3. Update profiles_select_all RLS — block-aware
-- =============================================================================
-- Previously: every authenticated user could read every non-deleted
-- profile. Now: the row is hidden if a user_blocks row exists in either
-- direction between the caller and the profile's owner.
--
-- This is "defense in depth" — the four visible_* views already filter
-- blocked pairs, but a direct read of `profiles` (e.g. profile detail
-- screens that don't go through a view) would still expose the blocker
-- to the blocked user, and vice versa. This closes that.

DROP POLICY IF EXISTS profiles_select_all ON public.profiles;

CREATE POLICY profiles_select_all
  ON public.profiles FOR SELECT
  USING (
    deleted_at IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
       WHERE (ub.created_by = auth.uid()        AND ub.blocked_user_id = profiles.id)
          OR (ub.created_by = profiles.id       AND ub.blocked_user_id = auth.uid())
    )
  );


-- =============================================================================
-- 4. user_blocks — add free-text reason note column
-- =============================================================================
-- reason_key is the categorical reason (inappropriate / spam / harassment /
-- fake_profile / other). reason_note is the optional free-text note the
-- blocker types about the other user — gives the admin queue extra context
-- when reviewing blocks/reports later.

ALTER TABLE public.user_blocks
  ADD COLUMN IF NOT EXISTS reason_note text;


-- =============================================================================
-- 5. RPCs: block_user / unblock_user
-- =============================================================================
-- Single FlutterFlow entry points so the client makes one rpc call rather
-- than a direct INSERT/DELETE on user_blocks. Both are SECURITY DEFINER so
-- they can succeed even if the caller already can't read the target's
-- profile through the RLS above (relevant on unblock).

-- ----- block_user --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.block_user(
  p_target_id   uuid,
  p_reason_key  text,
  p_reason_note text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_block_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_target_id IS NULL OR p_target_id = v_uid THEN
    RAISE EXCEPTION 'Invalid block target'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Idempotent: if already blocked, refresh the reason_key + reason_note
  -- (lets the user re-block with updated detail without erroring).
  INSERT INTO public.user_blocks (
    created_by, blocked_user_id, reason_key, reason_note
  )
  VALUES (v_uid, p_target_id, p_reason_key, p_reason_note)
  ON CONFLICT (created_by, blocked_user_id) DO UPDATE
     SET reason_key  = COALESCE(EXCLUDED.reason_key,  public.user_blocks.reason_key),
         reason_note = COALESCE(EXCLUDED.reason_note, public.user_blocks.reason_note)
  RETURNING id INTO v_block_id;

  RETURN v_block_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.block_user(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.block_user(uuid, text, text) TO authenticated;


-- ----- unblock_user ------------------------------------------------------
CREATE OR REPLACE FUNCTION public.unblock_user(p_target_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_count int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  DELETE FROM public.user_blocks
   WHERE created_by      = v_uid
     AND blocked_user_id = p_target_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count > 0;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.unblock_user(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.unblock_user(uuid) TO authenticated;


-- =============================================================================
-- 6. Recreate visible_notifications — block-aware
-- =============================================================================
-- Adds a symmetric user_blocks filter on related_user_id so notification
-- cards involving a blocked user (in either direction) disappear from the
-- Notifications screen. Otherwise stale "X wants to connect" / "X sent you
-- a message" cards would linger after a block, tapping into dead profiles
-- and chats.
--
-- Notifications without a related user (currently: 'trip_starts_tomorrow')
-- are left untouched by the new filter — they're system-generated about
-- the viewer's own trip and have no other party to block against.

DROP VIEW IF EXISTS public.visible_notifications;

CREATE VIEW public.visible_notifications AS
SELECT
  notification.id            AS notification_id,
  notification.created_at,
  notification.is_read,
  notification.type,
  notification.unread_count,

  notification.related_user_id,
  related_profile.first_name AS related_user_first_name,
  related_profile.last_name  AS related_user_last_name,
  related_photo.storage_path AS related_user_photo_path,

  notification.related_trip_id,
  trip_dep_airport.iata_code AS related_trip_dep_iata,
  trip_arr_airport.iata_code AS related_trip_arr_iata,

  notification.related_chat_id,

  CASE notification.type
    WHEN 'connection_request_received' THEN
      COALESCE(related_profile.first_name, 'Someone')
      || ' wants to connect'
      || COALESCE(' from your ' || trip_dep_airport.iata_code || ' trip', '')
    WHEN 'connection_accepted' THEN
      'You''re connected with '
      || COALESCE(related_profile.first_name, 'someone')
      || '. Chat is open.'
    WHEN 'new_message' THEN
      CASE
        WHEN notification.unread_count > 9 THEN
          '9+ new messages from '
          || COALESCE(related_profile.first_name, 'someone')
          || '.'
        WHEN notification.unread_count > 1 THEN
          notification.unread_count::text
          || ' new messages from '
          || COALESCE(related_profile.first_name, 'someone')
          || '.'
        ELSE
          'New message from '
          || COALESCE(related_profile.first_name, 'someone')
          || '.'
      END
    WHEN 'trip_starts_tomorrow' THEN
      'Your trip'
      || COALESCE(' to ' || trip_arr_airport.iata_code, '')
      || ' starts tomorrow.'
  END                        AS display_text

FROM public.notifications notification

LEFT JOIN public.profiles related_profile
  ON related_profile.id          = notification.related_user_id
  AND related_profile.deleted_at IS NULL

LEFT JOIN public.profile_photos related_photo
  ON related_photo.profile_id     = notification.related_user_id
  AND related_photo.display_order = 1
  AND related_photo.deleted_at    IS NULL

LEFT JOIN public.trips related_trip
  ON related_trip.id = notification.related_trip_id

LEFT JOIN public.airports trip_dep_airport
  ON trip_dep_airport.id = related_trip.departure_airport_id

LEFT JOIN public.airports trip_arr_airport
  ON trip_arr_airport.id = related_trip.arrival_airport_id

WHERE notification.deleted_at             IS NULL
  AND notification.auto_dismissed_in_chat = false
  AND notification.user_id                = auth.uid()
  -- NEW: hide notifications involving a blocked user (either direction).
  -- Notifications with no related_user_id (e.g. trip_starts_tomorrow) are
  -- always shown.
  AND (
    notification.related_user_id IS NULL
    OR NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
       WHERE (ub.created_by = auth.uid()                    AND ub.blocked_user_id = notification.related_user_id)
          OR (ub.created_by = notification.related_user_id  AND ub.blocked_user_id = auth.uid())
    )
  );

ALTER VIEW public.visible_notifications SET (security_invoker = true);
GRANT SELECT ON public.visible_notifications TO authenticated;


COMMIT;
