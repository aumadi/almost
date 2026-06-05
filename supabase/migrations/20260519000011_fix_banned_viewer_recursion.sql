-- =============================================================================
-- Almost App — Fix banned-viewer check recursion (RLS bug from 000010)
-- Generated: 2026-05-19
-- =============================================================================
-- 20260519000010 introduced inline subqueries on public.profiles inside
-- both profiles_select_all RLS and every visible_* view. Those inner
-- SELECTs on profiles re-trigger the same profiles_select_all policy,
-- causing recursive evaluation that either errors with "infinite
-- recursion detected" or silently returns nothing — net effect: regular
-- users cannot fetch any profile-touching data.
--
-- Fix: a single SECURITY DEFINER helper function am_i_admin_banned()
-- which bypasses RLS, returns boolean, and is used everywhere the
-- viewer-banned check needs to happen. Function is STABLE so the
-- planner only evaluates it once per query, not per row.
--
-- All previous changes from 000007 / 000010 are preserved; this
-- migration only swaps the inline NOT EXISTS subqueries for the
-- helper call, and respins every affected view/policy.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Helper function — SECURITY DEFINER, bypasses RLS on profiles
-- =============================================================================

CREATE OR REPLACE FUNCTION public.am_i_admin_banned()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.profiles
     WHERE id              = auth.uid()
       AND admin_banned_at IS NOT NULL
  );
$$;

REVOKE EXECUTE ON FUNCTION public.am_i_admin_banned() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.am_i_admin_banned() TO authenticated;


-- =============================================================================
-- 2. profiles_select_all RLS — use the helper instead of inline subquery
-- =============================================================================

DROP POLICY IF EXISTS profiles_select_all ON public.profiles;

CREATE POLICY profiles_select_all
  ON public.profiles FOR SELECT
  USING (
    -- Always allow reading own row (profile screen works even when banned).
    id = auth.uid()
    OR (
      deleted_at      IS NULL
      AND admin_banned_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.user_blocks ub
         WHERE (ub.created_by = auth.uid()  AND ub.blocked_user_id = profiles.id)
            OR (ub.created_by = profiles.id AND ub.blocked_user_id = auth.uid())
      )
      AND NOT public.am_i_admin_banned()
    )
  );


-- =============================================================================
-- 3. messages_select_participant RLS — use the helper
-- =============================================================================

DROP POLICY IF EXISTS messages_select_participant ON public.messages;

CREATE POLICY messages_select_participant
  ON public.messages FOR SELECT
  USING (
    deleted_at IS NULL
    AND NOT public.am_i_admin_banned()
    AND EXISTS (
      SELECT 1 FROM public.chats c
       WHERE c.id          = messages.chat_id
         AND c.deleted_at  IS NULL
         AND (c.user_a_id = auth.uid() OR c.user_b_id = auth.uid())
    )
  );


-- =============================================================================
-- 4. visible_crossed_paths — use the helper
-- =============================================================================

DROP VIEW IF EXISTS public.visible_crossed_paths;

CREATE VIEW public.visible_crossed_paths AS
WITH resolved AS (
  SELECT
    o.id                                                                        AS overlap_id,
    o.overlap_date,
    o.connection_type                                                           AS shared_intents,
    o.created_at                                                                AS matched_at,
    o.matched_airport_id,
    CASE WHEN o.user_a_id = auth.uid() THEN o.trip_a_id  ELSE o.trip_b_id  END  AS overlap_trip_id,
    CASE WHEN o.user_a_id = auth.uid() THEN o.user_b_id  ELSE o.user_a_id  END  AS other_user_id,
    CASE WHEN o.user_a_id = auth.uid() THEN o.trip_b_id  ELSE o.trip_a_id  END  AS other_trip_id
  FROM public.trip_overlaps o
  WHERE o.deleted_at IS NULL
    AND (o.user_a_id = auth.uid() OR o.user_b_id = auth.uid())
    AND NOT EXISTS (
      SELECT 1
        FROM public.user_blocks ub
       WHERE (ub.created_by = o.user_a_id AND ub.blocked_user_id = o.user_b_id)
          OR (ub.created_by = o.user_b_id AND ub.blocked_user_id = o.user_a_id)
    )
)
SELECT
  r.overlap_id, r.overlap_date, r.shared_intents, r.matched_at,
  r.overlap_trip_id,
  r.matched_airport_id                      AS overlap_airport_id,
  ap_match.iata_code                        AS overlap_airport_iata,
  ap_match.city                             AS overlap_airport_city,
  CASE
    WHEN t_me.departure_airport_id = r.matched_airport_id
         AND t_me.departure_date   = r.overlap_date  THEN 'departure'
    WHEN t_me.layover_airport_id   = r.matched_airport_id
         AND t_me.layover_date     = r.overlap_date  THEN 'layover'
    WHEN t_me.arrival_airport_id   = r.matched_airport_id
         AND t_me.arrival_date     = r.overlap_date  THEN 'arrival'
  END                                       AS overlap_type,
  r.other_user_id,
  p_other.first_name                        AS other_first_name,
  p_other.last_name                         AS other_last_name,
  p_other.bio                               AS other_bio,
  p_other.age_range                         AS other_age_range_key,
  age_label.label                           AS other_age_range_label,
  p_other.gender_identity                   AS other_gender_key,
  gender_label.label                        AS other_gender_label,
  p_other.open_to                           AS other_open_to,
  photo_other.storage_path                  AS other_photo_path,
  r.other_trip_id,
  ap_oth_dep.iata_code                      AS other_trip_dep_iata,
  ap_oth_arr.iata_code                      AS other_trip_arr_iata,
  t_other.departure_date                    AS other_trip_dep_date,
  t_other.arrival_date                      AS other_trip_arr_date,
  cr_latest.status                          AS request_status_with_other,
  (cr_latest.created_by = auth.uid())       AS request_sent_by_me,
  cr_latest.brief_note                      AS request_note,
  chat_with_other.id                        AS chat_id
FROM resolved r
JOIN public.trips t_me
  ON t_me.id = r.overlap_trip_id
JOIN public.airports ap_match
  ON ap_match.id = r.matched_airport_id
JOIN public.profiles p_other
  ON p_other.id         = r.other_user_id
  AND p_other.deleted_at IS NULL
LEFT JOIN public.profile_photos photo_other
  ON photo_other.profile_id     = r.other_user_id
  AND photo_other.display_order = 1
  AND photo_other.deleted_at    IS NULL
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'age_range'
     AND setting_option->>'key'   = p_other.age_range
   LIMIT 1
) age_label ON TRUE
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'gender_identity'
     AND setting_option->>'key'   = p_other.gender_identity
   LIMIT 1
) gender_label ON TRUE
JOIN public.trips t_other
  ON t_other.id         = r.other_trip_id
  AND t_other.deleted_at IS NULL
JOIN public.airports ap_oth_dep
  ON ap_oth_dep.id = t_other.departure_airport_id
JOIN public.airports ap_oth_arr
  ON ap_oth_arr.id = t_other.arrival_airport_id
LEFT JOIN LATERAL (
  SELECT cr.status, cr.created_by, cr.brief_note
    FROM public.connection_requests cr
   WHERE cr.deleted_at IS NULL
     AND (
          (cr.created_by = auth.uid()      AND cr.recipient_id = r.other_user_id)
       OR (cr.created_by = r.other_user_id AND cr.recipient_id = auth.uid())
     )
   ORDER BY
     CASE cr.status
       WHEN 'accepted' THEN 1
       WHEN 'pending'  THEN 2
       WHEN 'declined' THEN 3
     END
   LIMIT 1
) cr_latest ON TRUE
LEFT JOIN public.chats chat_with_other
  ON chat_with_other.user_a_id = LEAST(auth.uid(), r.other_user_id)
  AND chat_with_other.user_b_id = GREATEST(auth.uid(), r.other_user_id)
  AND chat_with_other.deleted_at IS NULL
WHERE (cr_latest.status IS DISTINCT FROM 'declined'
       OR cr_latest.created_by = auth.uid())
  AND NOT public.am_i_admin_banned();

ALTER VIEW public.visible_crossed_paths SET (security_invoker = true);
GRANT SELECT ON public.visible_crossed_paths TO authenticated;


-- =============================================================================
-- 5. visible_my_trips — use the helper inside visible_other_users CTE
-- =============================================================================

DROP VIEW IF EXISTS public.visible_my_trips;

CREATE VIEW public.visible_my_trips AS
SELECT
  trip.id            AS trip_id,
  trip.created_at    AS created_at,
  trip.departure_date,
  trip.layover_date,
  trip.arrival_date,
  trip.connection_type AS intents,
  departure_airport.id        AS departure_airport_id,
  departure_airport.iata_code AS departure_iata,
  departure_airport.city      AS departure_city,
  layover_airport.id          AS layover_airport_id,
  layover_airport.iata_code   AS layover_iata,
  layover_airport.city        AS layover_city,
  arrival_airport.id          AS arrival_airport_id,
  arrival_airport.iata_code   AS arrival_iata,
  arrival_airport.city        AS arrival_city,
  (trip.layover_airport_id IS NOT NULL) AS has_layover,
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
    WHERE NOT EXISTS (
      SELECT 1 FROM public.user_blocks existing_block
      WHERE (existing_block.created_by      = auth.uid()       AND existing_block.blocked_user_id = du.other_user_id)
         OR (existing_block.blocked_user_id = auth.uid()       AND existing_block.created_by      = du.other_user_id)
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.connection_requests declined_req
      WHERE declined_req.deleted_at   IS NULL
        AND declined_req.status       = 'declined'
        AND declined_req.recipient_id = auth.uid()
        AND declined_req.created_by   = du.other_user_id
    )
    AND NOT public.am_i_admin_banned()
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
-- 6. visible_my_chats — use the helper
-- =============================================================================

DROP VIEW IF EXISTS public.visible_my_chats;

CREATE VIEW public.visible_my_chats AS
WITH resolved AS (
  SELECT
    chat.id              AS chat_id,
    chat.created_at      AS chat_created_at,
    chat.last_message_at AS last_message_at,
    CASE WHEN chat.user_a_id = auth.uid()
         THEN chat.user_b_id
         ELSE chat.user_a_id
    END                  AS other_user_id
  FROM public.chats chat
  WHERE chat.deleted_at IS NULL
    AND (chat.user_a_id = auth.uid() OR chat.user_b_id = auth.uid())
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks existing_block
      WHERE (existing_block.created_by = chat.user_a_id AND existing_block.blocked_user_id = chat.user_b_id)
         OR (existing_block.created_by = chat.user_b_id AND existing_block.blocked_user_id = chat.user_a_id)
    )
    AND NOT public.am_i_admin_banned()
)
SELECT
  r.chat_id,
  r.other_user_id,
  r.chat_created_at,
  r.last_message_at,
  other_profile.first_name               AS other_first_name,
  other_profile.last_name                AS other_last_name,
  other_profile.age_range                AS other_age_range_key,
  age_label.label                        AS other_age_range_label,
  other_photo.storage_path               AS other_photo_path,
  accepted_request.overlap_id            AS chat_overlap_id,
  overlap_airport.iata_code              AS overlap_airport_iata,
  overlap_airport.city                   AS overlap_airport_city,
  source_overlap.overlap_date            AS overlap_date,
  source_overlap.connection_type         AS shared_intents,
  last_message.content                   AS last_message_content,
  last_message.created_by                AS last_message_sender_id,
  last_message.created_at                AS last_message_created_at,
  COALESCE(unread.unread_count, 0)       AS unread_count
FROM resolved r
JOIN public.profiles other_profile
  ON other_profile.id         = r.other_user_id
  AND other_profile.deleted_at IS NULL
LEFT JOIN public.profile_photos other_photo
  ON other_photo.profile_id     = r.other_user_id
  AND other_photo.display_order = 1
  AND other_photo.deleted_at    IS NULL
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'age_range'
     AND setting_option->>'key'   = other_profile.age_range
   LIMIT 1
) age_label ON TRUE
LEFT JOIN LATERAL (
  SELECT cr.overlap_id
    FROM public.connection_requests cr
   WHERE cr.deleted_at IS NULL
     AND cr.status      = 'accepted'
     AND (
          (cr.created_by = auth.uid()       AND cr.recipient_id = r.other_user_id)
       OR (cr.created_by = r.other_user_id AND cr.recipient_id = auth.uid())
     )
   LIMIT 1
) accepted_request ON TRUE
LEFT JOIN public.trip_overlaps source_overlap
  ON source_overlap.id = accepted_request.overlap_id
LEFT JOIN public.airports overlap_airport
  ON overlap_airport.id = source_overlap.matched_airport_id
LEFT JOIN LATERAL (
  SELECT m.content, m.created_by, m.created_at
    FROM public.messages m
   WHERE m.chat_id   = r.chat_id
     AND m.deleted_at IS NULL
   ORDER BY m.created_at DESC
   LIMIT 1
) last_message ON TRUE
LEFT JOIN LATERAL (
  SELECT COUNT(*)::int AS unread_count
    FROM public.messages m
   WHERE m.chat_id    = r.chat_id
     AND m.created_by <> auth.uid()
     AND m.is_read    = false
     AND m.deleted_at IS NULL
) unread ON TRUE;

ALTER VIEW public.visible_my_chats SET (security_invoker = true);
GRANT SELECT ON public.visible_my_chats TO authenticated;


-- =============================================================================
-- 7. visible_chat_detail — use the helper
-- =============================================================================

DROP VIEW IF EXISTS public.visible_chat_detail;

CREATE VIEW public.visible_chat_detail AS
WITH resolved AS (
  SELECT
    chat.id              AS chat_id,
    chat.created_at      AS chat_created_at,
    chat.last_message_at AS last_message_at,
    CASE WHEN chat.user_a_id = auth.uid()
         THEN chat.user_b_id
         ELSE chat.user_a_id
    END                  AS other_user_id
  FROM public.chats chat
  WHERE chat.deleted_at IS NULL
    AND (chat.user_a_id = auth.uid() OR chat.user_b_id = auth.uid())
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks existing_block
      WHERE (existing_block.created_by = chat.user_a_id AND existing_block.blocked_user_id = chat.user_b_id)
         OR (existing_block.created_by = chat.user_b_id AND existing_block.blocked_user_id = chat.user_a_id)
    )
    AND NOT public.am_i_admin_banned()
)
SELECT
  r.chat_id, r.chat_created_at, r.last_message_at,
  r.other_user_id,
  other_profile.first_name               AS other_first_name,
  other_profile.last_name                AS other_last_name,
  other_profile.bio                      AS other_bio,
  other_profile.age_range                AS other_age_range_key,
  age_label.label                        AS other_age_range_label,
  other_profile.gender_identity          AS other_gender_key,
  gender_label.label                     AS other_gender_label,
  other_profile.open_to                  AS other_open_to,
  other_photo.storage_path               AS other_photo_path,
  accepted_request.overlap_id            AS chat_overlap_id,
  overlap_airport.iata_code              AS overlap_airport_iata,
  overlap_airport.city                   AS overlap_airport_city,
  source_overlap.overlap_date            AS overlap_date,
  source_overlap.connection_type         AS shared_intents
FROM resolved r
JOIN public.profiles other_profile
  ON other_profile.id         = r.other_user_id
  AND other_profile.deleted_at IS NULL
LEFT JOIN public.profile_photos other_photo
  ON other_photo.profile_id     = r.other_user_id
  AND other_photo.display_order = 1
  AND other_photo.deleted_at    IS NULL
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'age_range'
     AND setting_option->>'key'   = other_profile.age_range
   LIMIT 1
) age_label ON TRUE
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'gender_identity'
     AND setting_option->>'key'   = other_profile.gender_identity
   LIMIT 1
) gender_label ON TRUE
LEFT JOIN LATERAL (
  SELECT cr.overlap_id
    FROM public.connection_requests cr
   WHERE cr.deleted_at IS NULL
     AND cr.status      = 'accepted'
     AND (
          (cr.created_by = auth.uid()       AND cr.recipient_id = r.other_user_id)
       OR (cr.created_by = r.other_user_id AND cr.recipient_id = auth.uid())
     )
   LIMIT 1
) accepted_request ON TRUE
LEFT JOIN public.trip_overlaps source_overlap
  ON source_overlap.id = accepted_request.overlap_id
LEFT JOIN public.airports overlap_airport
  ON overlap_airport.id = source_overlap.matched_airport_id;

ALTER VIEW public.visible_chat_detail SET (security_invoker = true);
GRANT SELECT ON public.visible_chat_detail TO authenticated;


-- =============================================================================
-- 8. visible_notifications — use the helper
-- =============================================================================

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
  -- Banned viewer sees only own-account notifications (related_user_id IS NULL).
  AND (
    notification.related_user_id IS NULL
    OR NOT public.am_i_admin_banned()
  );

ALTER VIEW public.visible_notifications SET (security_invoker = true);
GRANT SELECT ON public.visible_notifications TO authenticated;


COMMIT;
