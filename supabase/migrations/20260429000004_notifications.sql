-- =============================================================================
-- Almost App — Notifications Layer
-- Generated: 2026-04-29
-- =============================================================================
-- Adds the in-app notifications stack and the device registry for push:
--
--   1. user_devices table — stores per-device FCM tokens (multi-device per user)
--   2. notify_on_request_received       — trigger on connection_requests INSERT
--   3. handle_request_accepted (replace) — extends existing fn to insert notif
--   4. handle_message_inserted (replace) — extends existing fn to insert notif
--   5. notify_trips_starting_tomorrow()  — scans tomorrow's trips
--   6. pg_cron schedule for #5 (daily 09:00 UTC)
--   7. visible_notifications view        — ready to render notification cards
--
-- Push fan-out (notifications -> FCM) is OUT OF SCOPE for this migration.
-- It is configured separately as a Supabase Database Webhook on the
-- notifications table → Edge Function send-push-notification.
-- =============================================================================

BEGIN;


-- =============================================================================
-- Required extension
-- =============================================================================
-- pg_cron must be enabled in: Supabase Dashboard → Database → Extensions
CREATE EXTENSION IF NOT EXISTS pg_cron;


-- =============================================================================
-- 1. user_devices table
-- =============================================================================
-- One row per (user, device). Multi-device per user is supported.
-- fcm_token is UNIQUE so a re-login on the same device upserts cleanly.

CREATE TABLE IF NOT EXISTS public.user_devices (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  user_id         uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  fcm_token       text        NOT NULL UNIQUE,
  platform        text        NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
  last_active_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz
);

CREATE INDEX IF NOT EXISTS idx_user_devices_user_id
  ON public.user_devices(user_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_user_devices_fcm_token
  ON public.user_devices(fcm_token) WHERE deleted_at IS NULL;

ALTER TABLE public.user_devices ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_devices_select_own
  ON public.user_devices FOR SELECT
  USING (user_id = auth.uid() AND deleted_at IS NULL);

CREATE POLICY user_devices_insert_own
  ON public.user_devices FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY user_devices_update_own
  ON public.user_devices FOR UPDATE
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY user_devices_delete_own
  ON public.user_devices FOR DELETE
  USING (user_id = auth.uid());

DROP TRIGGER IF EXISTS set_updated_at_user_devices ON public.user_devices;
CREATE TRIGGER set_updated_at_user_devices
  BEFORE UPDATE ON public.user_devices
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();


-- =============================================================================
-- 2. notify_on_request_received
-- =============================================================================
-- When a pending connection_request is INSERTed, create a
-- 'connection_request_received' notification for the recipient. The notif's
-- related_trip_id points at the recipient's trip in the source overlap so the
-- UI can render "from your SFO trip".

CREATE OR REPLACE FUNCTION public.notify_on_request_received()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recipient_trip_id uuid;
BEGIN
  IF NEW.overlap_id IS NOT NULL THEN
    SELECT
      CASE
        WHEN source_overlap.user_a_id = NEW.recipient_id THEN source_overlap.trip_a_id
        ELSE source_overlap.trip_b_id
      END
      INTO v_recipient_trip_id
    FROM public.trip_overlaps source_overlap
    WHERE source_overlap.id = NEW.overlap_id;
  END IF;

  INSERT INTO public.notifications (user_id, type, related_user_id, related_trip_id)
  VALUES (
    NEW.recipient_id,
    'connection_request_received',
    NEW.created_by,
    v_recipient_trip_id
  );

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.notify_on_request_received() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.notify_on_request_received() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_notify_on_request_received ON public.connection_requests;
CREATE TRIGGER trg_notify_on_request_received
  AFTER INSERT ON public.connection_requests
  FOR EACH ROW
  WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION public.notify_on_request_received();


-- =============================================================================
-- 3. handle_request_accepted — extended to insert notification
-- =============================================================================
-- This function previously just created a chats row. Now it also notifies the
-- ORIGINAL SENDER ("Your request was accepted") with the new chat_id attached.

CREATE OR REPLACE FUNCTION public.handle_request_accepted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_a_id uuid;
  v_user_b_id uuid;
  v_chat_id   uuid;
BEGIN
  -- Safety: ignore self-requests if they somehow exist.
  IF NEW.created_by = NEW.recipient_id THEN
    RETURN NEW;
  END IF;

  v_user_a_id := LEAST(NEW.created_by, NEW.recipient_id);
  v_user_b_id := GREATEST(NEW.created_by, NEW.recipient_id);

  -- Find existing chat for this pair, or create it.
  SELECT id INTO v_chat_id
    FROM public.chats existing_chat
   WHERE existing_chat.user_a_id  = v_user_a_id
     AND existing_chat.user_b_id  = v_user_b_id
     AND existing_chat.deleted_at IS NULL;

  IF v_chat_id IS NULL THEN
    INSERT INTO public.chats (user_a_id, user_b_id)
    VALUES (v_user_a_id, v_user_b_id)
    RETURNING id INTO v_chat_id;
  END IF;

  -- Notify the original sender.
  INSERT INTO public.notifications (user_id, type, related_user_id, related_chat_id)
  VALUES (
    NEW.created_by,
    'connection_accepted',
    NEW.recipient_id,
    v_chat_id
  );

  RETURN NEW;
END;
$$;


-- =============================================================================
-- 4. handle_message_inserted — extended to insert notification
-- =============================================================================
-- This function previously just bumped chats.last_message_at. Now it also
-- notifies the OTHER user in the chat ("New message from X").

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
BEGIN
  UPDATE public.chats
     SET last_message_at = NEW.created_at
   WHERE id = NEW.chat_id;

  -- Determine which user is "the other one" (not the sender).
  SELECT chat.user_a_id, chat.user_b_id
    INTO v_user_a_id, v_user_b_id
    FROM public.chats chat
   WHERE chat.id = NEW.chat_id;

  v_other_user_id := CASE
    WHEN NEW.created_by = v_user_a_id THEN v_user_b_id
    ELSE v_user_a_id
  END;

  IF v_other_user_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, related_user_id, related_chat_id)
    VALUES (
      v_other_user_id,
      'new_message',
      NEW.created_by,
      NEW.chat_id
    );
  END IF;

  RETURN NEW;
END;
$$;


-- =============================================================================
-- 5. notify_trips_starting_tomorrow()
-- =============================================================================
-- Scans active trips departing tomorrow and inserts a 'trip_starts_tomorrow'
-- notification for each owner. Idempotent — won't double-insert if a
-- notification for the same trip already exists today.

CREATE OR REPLACE FUNCTION public.notify_trips_starting_tomorrow()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.notifications (user_id, type, related_trip_id)
  SELECT
    trip.created_by,
    'trip_starts_tomorrow',
    trip.id
  FROM public.trips trip
  JOIN public.profiles owner_profile
    ON owner_profile.id = trip.created_by
   AND owner_profile.deleted_at IS NULL
  WHERE trip.deleted_at IS NULL
    AND trip.departure_date = CURRENT_DATE + INTERVAL '1 day'
    AND NOT EXISTS (
      SELECT 1 FROM public.notifications existing
      WHERE existing.user_id        = trip.created_by
        AND existing.type           = 'trip_starts_tomorrow'
        AND existing.related_trip_id = trip.id
        AND existing.created_at::date = CURRENT_DATE
        AND existing.deleted_at     IS NULL
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.notify_trips_starting_tomorrow() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.notify_trips_starting_tomorrow() FROM anon, authenticated;


-- =============================================================================
-- 6. Schedule daily trip reminder via pg_cron
-- =============================================================================
-- Runs every day at 09:00 UTC. Adjust the cron expression if you prefer a
-- different time. Idempotent — drops the existing schedule if any.

DO $$
BEGIN
  PERFORM cron.unschedule('daily-trip-starts-tomorrow');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

SELECT cron.schedule(
  'daily-trip-starts-tomorrow',
  '0 9 * * *',
  $cron$SELECT public.notify_trips_starting_tomorrow();$cron$
);


-- =============================================================================
-- 7. visible_notifications view
-- =============================================================================
-- One flat row per notification with the related entities pre-joined and a
-- per-type display_text. Filtered to current user via auth.uid().

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

  -- Computed display text per type.
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
  ON related_profile.id         = notification.related_user_id
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

WHERE notification.deleted_at IS NULL
  AND notification.user_id    = auth.uid();

ALTER VIEW public.visible_notifications SET (security_invoker = true);
GRANT SELECT ON public.visible_notifications TO authenticated;


COMMIT;
