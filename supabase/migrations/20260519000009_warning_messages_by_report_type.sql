-- =============================================================================
-- Almost App — Admin warning notification flow (category-based text)
-- Generated: 2026-05-19
-- =============================================================================
-- Runs after 20260519000008 has committed the 'admin_warning' enum value
-- so it is safe to reference here.
--
-- What this migration does:
--
--   1. user_reports.admin_notes — admin's free-text note when reviewing
--      a report. Stored for admin's own records only; NEVER shown to the
--      warned user.
--
--   2. notifications.body — optional per-row display-text override. The
--      trigger writes the rendered warning into this column; future
--      notification types can also use it without schema bumps.
--
--   3. fire_admin_warning_notification trigger function — when a user_reports
--      row's action_taken transitions to 'warn', insert a notification
--      for the reported user with a FIXED short message selected from a
--      CASE on the report's reason_key. Admin does NOT write the text;
--      all warnings of the same category share identical wording.
--
--   4. AFTER UPDATE trigger on user_reports — fires the function only
--      when action_taken actually transitions into 'warn' (no re-fire on
--      other column updates or on re-saves of an already-warned row).
--
--   5. Recreate visible_notifications — prefer notification.body as
--      display_text when present; add the 'admin_warning' branch in the
--      CASE for the generic fallback when body is null.
--
-- The 'hate_speech' reason_key is supported (added to app_settings
-- out-of-band by ops). The CASE below covers all six block_reason values
-- currently in app_settings (inappropriate, spam, harassment,
-- fake_profile, hate_speech, other) and falls back generically for any
-- future/unknown key.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. user_reports.admin_notes — admin's internal note
-- =============================================================================

ALTER TABLE public.user_reports
  ADD COLUMN IF NOT EXISTS admin_notes text;


-- =============================================================================
-- 2. notifications.body — optional display-text override
-- =============================================================================

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS body text;


-- =============================================================================
-- 3. fire_admin_warning_notification — category-based warning text
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fire_admin_warning_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_body text;
BEGIN
  v_body := CASE NEW.reason_key
    WHEN 'inappropriate' THEN 'Warning: Inappropriate behavior reported on Almost.'
    WHEN 'spam'          THEN 'Warning: Spam activity reported on Almost.'
    WHEN 'harassment'    THEN 'Warning: Harassment reported on Almost.'
    WHEN 'fake_profile'  THEN 'Warning: Profile authenticity issue reported.'
    WHEN 'hate_speech'   THEN 'Warning: Hate speech reported on Almost.'
    ELSE                      'Warning: Please review our community guidelines.'
  END;

  INSERT INTO public.notifications (
    user_id, type, body
  )
  VALUES (
    NEW.reported_user_id,
    'admin_warning',
    v_body
  );

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fire_admin_warning_notification() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fire_admin_warning_notification() FROM anon, authenticated;


-- =============================================================================
-- 4. Trigger registration
-- =============================================================================

DROP TRIGGER IF EXISTS trg_fire_admin_warning_notification ON public.user_reports;
CREATE TRIGGER trg_fire_admin_warning_notification
  AFTER UPDATE ON public.user_reports
  FOR EACH ROW
  WHEN (NEW.action_taken = 'warn' AND OLD.action_taken IS DISTINCT FROM 'warn')
  EXECUTE FUNCTION public.fire_admin_warning_notification();


-- =============================================================================
-- 5. Recreate visible_notifications — add body override + admin_warning
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
  );

ALTER VIEW public.visible_notifications SET (security_invoker = true);
GRANT SELECT ON public.visible_notifications TO authenticated;


COMMIT;
