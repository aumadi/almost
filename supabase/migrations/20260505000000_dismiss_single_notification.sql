-- =============================================================================
-- Almost App — Per-notification auto-dismiss (replaces chat-scoped variant)
-- Generated: 2026-05-05
-- =============================================================================
-- The previous dismiss_chat_notifications(p_chat_id) was too aggressive: it
-- auto-dismissed EVERY unread new_message notification for that chat,
-- including ones from yesterday or ones received while the user was OUTSIDE
-- the chat. The intent of auto_dismissed_in_chat is "this one push arrived
-- while I was already staring at the matching chat" — nothing more.
--
-- The Edge Function already includes notification_id in the FCM data
-- payload, so the foreground handler can hand us the exact id to dismiss.
--
-- Two changes:
--   1. Drop dismiss_chat_notifications(uuid) — scope was wrong.
--   2. Add dismiss_notification(p_notification_id uuid) — flips is_read = true
--      AND auto_dismissed_in_chat = true on exactly one row, scoped to the
--      calling user via auth.uid().
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Remove the over-broad RPC
-- =============================================================================

DROP FUNCTION IF EXISTS public.dismiss_chat_notifications(uuid);


-- =============================================================================
-- 2. Per-notification dismiss
-- =============================================================================
-- Called by the foreground FCM handler when a new_message push arrives AND
-- FFAppState().currentChatId matches data.related_chat_id. The handler reads
-- data.notification_id from the FCM payload and passes it here so this one
-- row never appears in the Notifications screen.
--
-- SECURITY INVOKER — RLS notifications_update_own permits the caller to
-- update their own notifications. The user_id = auth.uid() filter is a
-- belt-and-braces guard so a stale id from another user is a no-op.

CREATE OR REPLACE FUNCTION public.dismiss_notification(p_notification_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.notifications
     SET is_read                = true,
         auto_dismissed_in_chat = true
   WHERE id                     = p_notification_id
     AND user_id                = auth.uid()
     AND deleted_at             IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.dismiss_notification(uuid) TO authenticated;


COMMIT;
