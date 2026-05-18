-- =============================================================================
-- Almost App — Mark-as-read RPCs (notifications + chat messages)
-- Generated: 2026-04-29
-- =============================================================================
-- Two RPCs for clearing unread state from the UI:
--
--   1. mark_all_my_notifications_read()
--      Flips is_read = true on all of my unread notifications.
--      SECURITY INVOKER — RLS notifications_update_own permits the caller
--      to update their own rows.
--
--   2. mark_chat_messages_read(p_chat_id uuid)
--      Flips is_read = true on messages in a chat that I did NOT send.
--      SECURITY DEFINER — needed because RLS messages_update_own only lets
--      a user update their OWN messages (created_by = auth.uid()), and we
--      need to mark messages received from the OTHER user. The function
--      first verifies the caller is a participant of the chat as its own
--      authorization check, then runs the UPDATE.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. mark_all_my_notifications_read
-- =============================================================================

CREATE OR REPLACE FUNCTION public.mark_all_my_notifications_read()
RETURNS int
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.notifications
     SET is_read = true
   WHERE user_id    = auth.uid()
     AND is_read    = false
     AND deleted_at IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_all_my_notifications_read() TO authenticated;


-- =============================================================================
-- 2. mark_chat_messages_read
-- =============================================================================
-- SECURITY DEFINER, but performs its own authorization check first.
-- Caller must be a participant (user_a or user_b) of the chat. Otherwise
-- the function raises an exception and updates nothing.

CREATE OR REPLACE FUNCTION public.mark_chat_messages_read(p_chat_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  -- Authorization: caller must be a participant of the chat.
  IF NOT EXISTS (
    SELECT 1
      FROM public.chats c
     WHERE c.id          = p_chat_id
       AND c.deleted_at  IS NULL
       AND (c.user_a_id = auth.uid() OR c.user_b_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'Not a participant of chat %', p_chat_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Mark unread messages from the OTHER user as read.
  -- We never touch messages the caller themselves sent (those track
  -- whether the recipient has read them).
  UPDATE public.messages
     SET is_read = true
   WHERE chat_id    = p_chat_id
     AND is_read    = false
     AND created_by <> auth.uid()
     AND deleted_at IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_chat_messages_read(uuid) TO authenticated;


COMMIT;
