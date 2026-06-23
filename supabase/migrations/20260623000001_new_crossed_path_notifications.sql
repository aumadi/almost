-- =============================================================================
-- Almost App — Notify on new crossed-paths
-- Generated: 2026-06-23
-- =============================================================================
-- Runs after 20260623000000 has committed the two new enum values so it
-- is safe to reference 'new_crossed_path' and 'crossed_paths_summary'
-- here.
--
-- Product spec (decided 2026-06-23):
--
--   When user A inserts/edits a trip and the matching algorithm creates
--   NEW trip_overlaps rows:
--
--   • Each matched user (B, C, D, ...) receives one in-app notification
--     PER A-trip — type 'new_crossed_path'. Body:
--       "<A's first name> is on your <matched airport> trip."
--     Coalesce key: (recipient, related_user_id = A, related_trip_id = A's trip).
--     If A adds another trip later that matches the same user, that's a
--     NEW card (different related_trip_id).
--     Within one trip add, multiple slot-overlaps with the same recipient
--     collapse into the one card.
--
--   • The trip creator (A) receives ONE summary notification per trip add
--     that produced overlaps — type 'crossed_paths_summary'. Body:
--       "You have N new crossed path(s) from your <airport> trip."
--     Coalesce key: (creator, type, related_trip_id). If A edits the
--     same trip later and gains more overlaps, the existing summary's
--     unread_count + body are updated; no second card is created for
--     the same trip.
--
--   Only TRULY NEW overlap rows (the final INSERT in v2's CTE chain)
--   produce notifications. Reactivated overlaps don't — the user has
--   seen them before.
--
-- This migration:
--   1. Rewrites compute_overlaps_for_trip_v2 to capture the INSERT's
--      RETURNING and emit notifications.
--   2. Recreates visible_notifications view with display_text branches
--      for the two new types (defensive — body is normally pre-computed
--      at insert time and rendered directly).
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. compute_overlaps_for_trip_v2 — emit notifications after new inserts
-- =============================================================================

CREATE OR REPLACE FUNCTION public.compute_overlaps_for_trip_v2(p_trip_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_trip              public.trips%ROWTYPE;
  v_owner_complete    boolean;
  v_owner_banned      boolean;
  v_owner_first_name  text;
  v_owner_airport     text;
  v_new_overlap       record;
  v_new_count         int := 0;
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

  -- Owner gate: profile must be complete + not banned + not deleted.
  -- Also capture first_name + departure_iata for the body text.
  SELECT p.profile_complete,
         (p.admin_banned_at IS NOT NULL),
         p.first_name
    INTO v_owner_complete, v_owner_banned, v_owner_first_name
    FROM public.profiles p
   WHERE p.id          = v_trip.created_by
     AND p.deleted_at  IS NULL;

  IF NOT COALESCE(v_owner_complete, false) OR COALESCE(v_owner_banned, true) THEN
    RETURN;
  END IF;

  SELECT ap.iata_code
    INTO v_owner_airport
    FROM public.airports ap
   WHERE ap.id = v_trip.departure_airport_id;

  -- =====================================================================
  -- CTE chain identical to the previous v2 — soft_delete, reactivate,
  -- intent_refresh, then the final INSERT. We capture RETURNING so we
  -- can fire notifications per newly created overlap.
  -- =====================================================================
  FOR v_new_overlap IN
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
               AND candidate_profile.admin_banned_at  IS NULL
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
      se.user_a_id, se.user_b_id, se.trip_a_id, se.trip_b_id,
      se.matched_airport_id, se.overlap_date, se.connection_type
      FROM should_exist se
     WHERE NOT EXISTS (
       SELECT 1
         FROM public.trip_overlaps existing_overlap
        WHERE existing_overlap.trip_a_id          = se.trip_a_id
          AND existing_overlap.trip_b_id          = se.trip_b_id
          AND existing_overlap.matched_airport_id = se.matched_airport_id
          AND existing_overlap.overlap_date       = se.overlap_date
     )
    ON CONFLICT (trip_a_id, trip_b_id, matched_airport_id, overlap_date) DO NOTHING
    RETURNING id, user_a_id, user_b_id, trip_a_id, trip_b_id, matched_airport_id
  LOOP
    -- =================================================================
    -- Per-overlap: emit a new_crossed_path notification for the OTHER
    -- user (not the trip creator). Coalesce by (recipient, sender,
    -- sender's trip) — so multiple slot-matches in this same trip add
    -- collapse into one card for that recipient.
    -- =================================================================
    DECLARE
      v_matched_user         uuid;
      v_matched_trip         uuid;
      v_matched_airport_iata text;
      v_body                 text;
    BEGIN
      IF v_new_overlap.user_a_id = v_trip.created_by THEN
        v_matched_user := v_new_overlap.user_b_id;
        v_matched_trip := v_new_overlap.trip_b_id;
      ELSE
        v_matched_user := v_new_overlap.user_a_id;
        v_matched_trip := v_new_overlap.trip_a_id;
      END IF;

      SELECT ap.iata_code
        INTO v_matched_airport_iata
        FROM public.airports ap
       WHERE ap.id = v_new_overlap.matched_airport_id;

      v_body :=
        COALESCE(v_owner_first_name, 'Someone')
        || ' is on your '
        || COALESCE(v_matched_airport_iata, 'trip')
        || ' trip.';

      -- Bump existing unread card if present (same recipient + sender + sender-trip).
      UPDATE public.notifications
         SET created_at        = now(),
             unread_count      = unread_count + 1,
             body              = v_body
       WHERE user_id           = v_matched_user
         AND type              = 'new_crossed_path'
         AND related_user_id   = v_trip.created_by
         AND related_trip_id   = p_trip_id
         AND is_read           = false
         AND deleted_at        IS NULL;

      IF NOT FOUND THEN
        INSERT INTO public.notifications (
          user_id, type, related_user_id, related_trip_id, body, unread_count
        ) VALUES (
          v_matched_user,
          'new_crossed_path',
          v_trip.created_by,
          p_trip_id,                       -- coalesce key = A's trip
          v_body,
          1
        );
      END IF;
    END;

    v_new_count := v_new_count + 1;
  END LOOP;

  -- =====================================================================
  -- Trip creator's summary: ONE card per trip add that produced overlaps.
  -- Coalesce by (creator, type, related_trip_id) — if A re-edits the same
  -- trip later, the existing card's count is bumped instead of a new one.
  -- =====================================================================
  IF v_new_count > 0 THEN
    DECLARE
      v_existing_count int;
      v_total_count    int;
      v_summary_body   text;
    BEGIN
      SELECT unread_count
        INTO v_existing_count
        FROM public.notifications
       WHERE user_id         = v_trip.created_by
         AND type            = 'crossed_paths_summary'
         AND related_trip_id = p_trip_id
         AND is_read         = false
         AND deleted_at      IS NULL
       LIMIT 1;

      v_total_count := COALESCE(v_existing_count, 0) + v_new_count;
      v_summary_body :=
        'You have ' || v_total_count::text
        || ' new crossed path' || CASE WHEN v_total_count > 1 THEN 's' ELSE '' END
        || ' from your '
        || COALESCE(v_owner_airport, 'trip')
        || ' trip.';

      IF v_existing_count IS NOT NULL THEN
        UPDATE public.notifications
           SET created_at   = now(),
               unread_count = v_total_count,
               body         = v_summary_body
         WHERE user_id         = v_trip.created_by
           AND type            = 'crossed_paths_summary'
           AND related_trip_id = p_trip_id
           AND is_read         = false
           AND deleted_at      IS NULL;
      ELSE
        INSERT INTO public.notifications (
          user_id, type, related_trip_id, body, unread_count
        ) VALUES (
          v_trip.created_by,
          'crossed_paths_summary',
          p_trip_id,
          v_summary_body,
          v_new_count
        );
      END IF;
    END;
  END IF;
END;
$$;


-- =============================================================================
-- 2. visible_notifications — add display fallbacks for the two new types
-- =============================================================================
-- Body is normally pre-computed at insert time and rendered verbatim via
-- the COALESCE/NULLIF chain. The CASE branches below are defensive
-- fallbacks if a row ends up without a body (shouldn't happen for these
-- types in practice).

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
  COALESCE(
    NULLIF(notification.body, ''),
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
            || COALESCE(related_profile.first_name, 'someone') || '.'
          WHEN notification.unread_count > 1 THEN
            notification.unread_count::text
            || ' new messages from '
            || COALESCE(related_profile.first_name, 'someone') || '.'
          ELSE
            'New message from '
            || COALESCE(related_profile.first_name, 'someone') || '.'
        END
      WHEN 'trip_starts_tomorrow' THEN
        'Your trip'
        || COALESCE(' to ' || trip_arr_airport.iata_code, '')
        || ' starts tomorrow.'
      WHEN 'admin_warning' THEN
        'Warning: Please review our community guidelines.'
      WHEN 'new_crossed_path' THEN
        COALESCE(related_profile.first_name, 'Someone')
        || ' is on your '
        || COALESCE(trip_dep_airport.iata_code, 'trip')
        || ' trip.'
      WHEN 'crossed_paths_summary' THEN
        'You have '
        || COALESCE(notification.unread_count, 1)::text
        || ' new crossed paths from your '
        || COALESCE(trip_dep_airport.iata_code, 'trip')
        || ' trip.'
    END
  )                          AS display_text
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
  AND (
    notification.related_user_id IS NULL
    OR NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
       WHERE (ub.created_by = auth.uid()                    AND ub.blocked_user_id = notification.related_user_id)
          OR (ub.created_by = notification.related_user_id  AND ub.blocked_user_id = auth.uid())
    )
  )
  AND (
    notification.related_user_id IS NULL
    OR NOT public.am_i_admin_banned()
  );

ALTER VIEW public.visible_notifications SET (security_invoker = true);
GRANT SELECT ON public.visible_notifications TO authenticated;


COMMIT;
