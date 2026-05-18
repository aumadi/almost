-- =============================================================================
-- Almost App — Auto-dismissed notifications
-- Generated: 2026-04-29
-- =============================================================================
-- When a user is actively in a chat and a new_message notification arrives
-- for that same chat, the client marks it auto-dismissed so it never shows
-- in the Notifications screen. This keeps the screen clean of "messages
-- you literally just read" entries.
--
-- Three changes:
--
--   1. Add column notifications.auto_dismissed_in_chat (boolean, default false)
--   2. Update visible_notifications to hide rows where this flag is true
--   3. Add RPC dismiss_chat_notifications(p_chat_id uuid) — flips both
--      is_read = true and auto_dismissed_in_chat = true for all unread
--      new_message notifications in the given chat for the calling user.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Add the flag column
-- =============================================================================

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS auto_dismissed_in_chat boolean NOT NULL DEFAULT false;

-- Helpful partial index for the common visible_notifications query path:
-- "active, not auto-dismissed, current user".
CREATE INDEX IF NOT EXISTS idx_notifications_user_visible
  ON public.notifications(user_id, created_at DESC)
  WHERE deleted_at IS NULL
    AND auto_dismissed_in_chat = false;


-- =============================================================================
-- 2. Recreate visible_notifications with the auto-dismissed filter
-- =============================================================================

DROP VIEW IF EXISTS public.visible_notifications;

CREATE VIEW public.visible_notifications AS
SELECT
  notification.id            AS notification_id,
  notification.created_at,
  notification.is_read,
  notification.type,

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
      'New message from '
      || COALESCE(related_profile.first_name, 'someone')
      || '.'
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
  ON related_photo.profile_id    = notification.related_user_id
  AND related_photo.display_order = 1
  AND related_photo.deleted_at   IS NULL

LEFT JOIN public.trips related_trip
  ON related_trip.id = notification.related_trip_id

LEFT JOIN public.airports trip_dep_airport
  ON trip_dep_airport.id = related_trip.departure_airport_id

LEFT JOIN public.airports trip_arr_airport
  ON trip_arr_airport.id = related_trip.arrival_airport_id

WHERE notification.deleted_at             IS NULL
  AND notification.auto_dismissed_in_chat = false   -- new
  AND notification.user_id                = auth.uid();

ALTER VIEW public.visible_notifications SET (security_invoker = true);
GRANT SELECT ON public.visible_notifications TO authenticated;


-- =============================================================================
-- 3. RPC: dismiss_chat_notifications
-- =============================================================================
-- Called by the client when a new_message notification arrives while the user
-- is on the matching Chat Detail screen. Marks all unread new_message
-- notifications for this chat as both read and auto-dismissed so they never
-- appear in the Notifications screen.
--
-- SECURITY INVOKER — RLS notifications_update_own permits the caller to
-- update their own notifications.

CREATE OR REPLACE FUNCTION public.dismiss_chat_notifications(p_chat_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.notifications
     SET is_read                 = true,
         auto_dismissed_in_chat  = true
   WHERE user_id                 = auth.uid()
     AND related_chat_id         = p_chat_id
     AND type                    = 'new_message'
     AND deleted_at              IS NULL
     AND (is_read = false OR auto_dismissed_in_chat = false);

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.dismiss_chat_notifications(uuid) TO authenticated;


COMMIT;
