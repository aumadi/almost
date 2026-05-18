-- =============================================================================
-- Almost App — Carry trip context on connection_accepted notifications
-- Generated: 2026-05-12
-- =============================================================================
-- notify_on_request_received already stores related_trip_id (the RECIPIENT's
-- trip from the source overlap) so the UI can render "from your SFO trip".
-- handle_request_accepted, however, was leaving related_trip_id NULL, so the
-- accepted-notification side lost that context.
--
-- This migration extends handle_request_accepted to look up the ORIGINAL
-- SENDER's trip in the same overlap and store it on the notification row.
-- The accepted notification therefore carries: the user who accepted
-- (related_user_id), the sender's own trip from the overlap (related_trip_id),
-- and the new chat (related_chat_id).
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.handle_request_accepted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_a_id      uuid;
  v_user_b_id      uuid;
  v_chat_id        uuid;
  v_sender_trip_id uuid;
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

  -- Look up the original sender's trip from the source overlap so the
  -- notification can render "your SFO trip" on the accepted card too.
  -- Mirrors the lookup notify_on_request_received does for the recipient.
  IF NEW.overlap_id IS NOT NULL THEN
    SELECT
      CASE
        WHEN source_overlap.user_a_id = NEW.created_by THEN source_overlap.trip_a_id
        ELSE source_overlap.trip_b_id
      END
      INTO v_sender_trip_id
    FROM public.trip_overlaps source_overlap
    WHERE source_overlap.id = NEW.overlap_id;
  END IF;

  -- Notify the original sender.
  INSERT INTO public.notifications (
    user_id, type, related_user_id, related_trip_id, related_chat_id
  )
  VALUES (
    NEW.created_by,
    'connection_accepted',
    NEW.recipient_id,
    v_sender_trip_id,
    v_chat_id
  );

  RETURN NEW;
END;
$$;

COMMIT;
