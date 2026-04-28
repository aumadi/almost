-- =============================================================================
-- Almost App — Chat Views + Crossed Paths Additions
-- Generated: 2026-04-24
-- =============================================================================
-- This migration adds the read models for the Messages screen, augments the
-- Crossed Paths view, and adds a header view for the Chat Detail screen:
--
--   1. visible_my_chats (new)
--        One row per chat the current user is part of. Identity + overlap
--        context (airport, date, intents) pulled from the accepted
--        connection_request that led to the chat. Matches the Figma "Chats"
--        screen which shows photo + name + airport/date + intent badge.
--
--   2. visible_crossed_paths (update)
--        Adds chat_id (for the Message button on accepted matches) and
--        request_note (sender's note, useful for UI context).
--
--   3. visible_chat_detail (new)
--        Header data for the Chat Detail screen. Richer than visible_my_chats
--        — includes bio, gender, open_to for a fuller header. One row per chat
--        (filter by chat_id).
-- =============================================================================


-- =============================================================================
-- 1. VIEW: visible_my_chats
-- =============================================================================

DROP VIEW IF EXISTS public.visible_my_chats;

CREATE VIEW public.visible_my_chats AS
WITH resolved AS (
  -- Resolve "other user" once per chat + filter participants + blocks + soft deletes.
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
)
SELECT
  -- Navigation (2)
  r.chat_id,
  r.other_user_id,

  -- Sorting (2)
  r.chat_created_at,
  r.last_message_at,

  -- Other user identity (5)
  other_profile.first_name               AS other_first_name,
  other_profile.last_name                AS other_last_name,
  other_profile.age_range                AS other_age_range_key,
  age_label.label                        AS other_age_range_label,
  other_photo.storage_path               AS other_photo_path,

  -- Overlap context from the accepted connection_request (5)
  accepted_request.overlap_id            AS chat_overlap_id,
  overlap_airport.iata_code              AS overlap_airport_iata,
  overlap_airport.city                   AS overlap_airport_city,
  source_overlap.overlap_date            AS overlap_date,
  source_overlap.connection_type         AS shared_intents,

  -- Last message preview (3)
  last_message.content                   AS last_message_content,
  last_message.created_by                AS last_message_sender_id,
  last_message.created_at                AS last_message_created_at,

  -- Unread badge (1) — count of messages sent by the OTHER user that I
  -- haven't read yet. Messages I sent don't count.
  COALESCE(unread.unread_count, 0)       AS unread_count

FROM resolved r

JOIN public.profiles other_profile
  ON other_profile.id         = r.other_user_id
  AND other_profile.deleted_at IS NULL

LEFT JOIN public.profile_photos other_photo
  ON other_photo.profile_id     = r.other_user_id
  AND other_photo.display_order = 1
  AND other_photo.deleted_at    IS NULL

-- Age-range label from app_settings JSONB
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'age_range'
     AND setting_option->>'key'   = other_profile.age_range
   LIMIT 1
) age_label ON TRUE

-- The accepted connection_request between me and the other user.
-- One such row always exists if a chat exists (chat is created on accept).
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

-- The overlap row that led to the request (may be soft-deleted; fields NULL then).
LEFT JOIN public.trip_overlaps source_overlap
  ON source_overlap.id = accepted_request.overlap_id

LEFT JOIN public.airports overlap_airport
  ON overlap_airport.id = source_overlap.matched_airport_id

-- Most recent message in this chat (preview for the list).
LEFT JOIN LATERAL (
  SELECT m.content, m.created_by, m.created_at
    FROM public.messages m
   WHERE m.chat_id   = r.chat_id
     AND m.deleted_at IS NULL
   ORDER BY m.created_at DESC
   LIMIT 1
) last_message ON TRUE

-- Unread count for me: messages I didn't send AND haven't been marked read.
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
-- 2. UPDATE visible_crossed_paths — add chat_id + request_note
-- =============================================================================
-- Two new fields:
--   chat_id      — present when an accepted request exists between the pair;
--                  enables the Message button to navigate to the chat
--   request_note — the brief note from whichever request "won" the LATERAL
--                  priority lookup (accepted > pending > declined)
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
  -- Overlap identity (4)
  r.overlap_id,
  r.overlap_date,
  r.shared_intents,
  r.matched_at,

  -- Overlap context — drives group header (5)
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

  -- Other user — card content (10)
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

  -- Other user's trip — card subtext (5)
  r.other_trip_id,
  ap_oth_dep.iata_code                      AS other_trip_dep_iata,
  ap_oth_arr.iata_code                      AS other_trip_arr_iata,
  t_other.departure_date                    AS other_trip_dep_date,
  t_other.arrival_date                      AS other_trip_arr_date,

  -- Connect button state + note (3, was 2)
  cr_latest.status                          AS request_status_with_other,
  (cr_latest.created_by = auth.uid())       AS request_sent_by_me,
  cr_latest.brief_note                      AS request_note,

  -- Chat navigation (1) — populated once the request is accepted
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

-- Connect request between me and the other user (either direction).
-- Picks one row with priority: accepted > pending > declined.
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

-- Chat between me and the other user (present once request is accepted).
LEFT JOIN public.chats chat_with_other
  ON chat_with_other.user_a_id = LEAST(auth.uid(), r.other_user_id)
  AND chat_with_other.user_b_id = GREATEST(auth.uid(), r.other_user_id)
  AND chat_with_other.deleted_at IS NULL;


ALTER VIEW public.visible_crossed_paths SET (security_invoker = true);
GRANT SELECT ON public.visible_crossed_paths TO authenticated;


-- =============================================================================
-- 3. VIEW: visible_chat_detail
-- =============================================================================
-- Header data for the Chat Detail screen. One row per chat, with richer
-- profile fields than visible_my_chats (bio, gender, open_to) since the
-- detail header can surface more context than a list card.
--
-- FlutterFlow usage:
--   SELECT * FROM visible_chat_detail WHERE chat_id = <the_chat_id>
--   → returns 1 row with everything the header needs.
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
)
SELECT
  -- Chat identity (3)
  r.chat_id,
  r.chat_created_at,
  r.last_message_at,

  -- Other user — full profile fields for the header (10)
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

  -- Overlap context from the accepted request (5)
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
