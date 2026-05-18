-- =============================================================================
-- Almost App — Coalesce new_message notifications
-- Generated: 2026-05-12
-- =============================================================================
-- Industry-standard chat-thread collapse (WhatsApp / iMessage / Slack):
-- while an unread + non-dismissed new_message notification already exists for
-- (recipient, chat), additional incoming messages just BUMP that one row
-- (created_at = now(), unread_count += 1) instead of inserting fresh rows.
-- Once the user reads it (mark_chat_messages_read flips is_read = true) the
-- next message creates a brand-new row, so they get a fresh card next time.
--
-- The Database Webhook must be reconfigured to fire on UPDATE as well as
-- INSERT (Dashboard → Database → Webhooks → Edit → check "Update"). The
-- Edge Function ignores UPDATEs that didn't actually bump unread_count, so
-- is_read / auto_dismissed_in_chat flips will never produce a push.
--
-- Three changes:
--   1. Add notifications.unread_count (int, default 1)
--   2. Rewrite handle_message_inserted: UPDATE-first, INSERT-if-no-row-bumped
--   3. Recreate visible_notifications view: expose unread_count + use it in
--      display_text for new_message ("4 new messages from John.")
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Add unread_count column
-- =============================================================================

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS unread_count int NOT NULL DEFAULT 1;


-- =============================================================================
-- 2. Rewrite handle_message_inserted with find-or-update-else-insert
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_message_inserted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_a_id     uuid;
  v_user_b_id     uuid;
  v_other_user_id uuid;
  v_updated_rows  int;
BEGIN
  UPDATE public.chats
     SET last_message_at = NEW.created_at
   WHERE id = NEW.chat_id;

  SELECT chat.user_a_id, chat.user_b_id
    INTO v_user_a_id, v_user_b_id
    FROM public.chats chat
   WHERE chat.id = NEW.chat_id;

  v_other_user_id := CASE
    WHEN NEW.created_by = v_user_a_id THEN v_user_b_id
    ELSE v_user_a_id
  END;

  IF v_other_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Try to bump an existing active row first. "Active" = unread, not
  -- auto-dismissed, not soft-deleted. This is the same predicate the
  -- visible_notifications view uses, so we never coalesce into a row the
  -- user has already cleared.
  UPDATE public.notifications
     SET created_at   = now(),
         unread_count = unread_count + 1
   WHERE user_id                = v_other_user_id
     AND related_chat_id        = NEW.chat_id
     AND type                   = 'new_message'
     AND is_read                = false
     AND auto_dismissed_in_chat = false
     AND deleted_at             IS NULL;

  GET DIAGNOSTICS v_updated_rows = ROW_COUNT;

  -- No active row to bump → insert a fresh one.
  IF v_updated_rows = 0 THEN
    INSERT INTO public.notifications (
      user_id, type, related_user_id, related_chat_id, unread_count
    )
    VALUES (
      v_other_user_id,
      'new_message',
      NEW.created_by,
      NEW.chat_id,
      1
    );
  END IF;

  RETURN NEW;
END;
$$;


-- =============================================================================
-- 3. Recreate visible_notifications view with unread_count + plural body
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
  AND notification.user_id                = auth.uid();

ALTER VIEW public.visible_notifications SET (security_invoker = true);
GRANT SELECT ON public.visible_notifications TO authenticated;


COMMIT;
