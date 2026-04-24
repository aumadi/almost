-- =============================================================================
-- Almost App — Connect Flow
-- Generated: 2026-04-24
-- =============================================================================
-- Adds the server-side pieces that complete the connect flow:
--
--   1. Trigger on connection_requests: when status flips pending -> accepted,
--      auto-create a chat row for the two users.
--
--   2. Trigger on messages: when a message is inserted, bump the chat's
--      last_message_at so the Messages screen can sort by recency.
--
--   3. View visible_incoming_requests: read model for the "Request Received"
--      section at the top of the Crossed Paths screen. Pre-joins the sender's
--      profile + primary photo + age_range/gender labels.
--
-- Everything else the connect flow needs (sending a request, updating status,
-- sending a message) is handled by existing RLS policies + FlutterFlow default
-- INSERT/UPDATE actions — no additional server code required.
-- =============================================================================


-- =============================================================================
-- 1. FUNCTION + TRIGGER: auto-create chat on request acceptance
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_request_accepted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_a_id uuid;
  v_user_b_id uuid;
BEGIN
  -- Safety: ignore self-requests if they somehow exist.
  IF NEW.created_by = NEW.recipient_id THEN
    RETURN NEW;
  END IF;

  -- Canonical ordering (same as trip_overlaps + the functional unique index
  -- on chats). The smaller uuid always goes into user_a_id and the larger
  -- into user_b_id, so every pair has exactly one chat regardless of who
  -- requested whom.
  v_user_a_id := LEAST(NEW.created_by, NEW.recipient_id);
  v_user_b_id := GREATEST(NEW.created_by, NEW.recipient_id);

  -- Create the chat only if one doesn't already exist for this pair.
  -- (Handles the edge case of bidirectional requests: if Alice -> Bob and
  --  Bob -> Alice both exist and both get accepted, only one chat results.)
  INSERT INTO public.chats (user_a_id, user_b_id)
  SELECT v_user_a_id, v_user_b_id
  WHERE NOT EXISTS (
    SELECT 1
      FROM public.chats existing_chat
     WHERE existing_chat.user_a_id  = v_user_a_id
       AND existing_chat.user_b_id  = v_user_b_id
       AND existing_chat.deleted_at IS NULL
  );

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.handle_request_accepted() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.handle_request_accepted() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_create_chat_on_accept ON public.connection_requests;
CREATE TRIGGER trg_create_chat_on_accept
  AFTER UPDATE ON public.connection_requests
  FOR EACH ROW
  WHEN (OLD.status = 'pending' AND NEW.status = 'accepted')
  EXECUTE FUNCTION public.handle_request_accepted();


-- =============================================================================
-- 2. FUNCTION + TRIGGER: keep chats.last_message_at in sync
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_message_inserted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.chats
     SET last_message_at = NEW.created_at
   WHERE id = NEW.chat_id;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.handle_message_inserted() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.handle_message_inserted() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_update_chat_last_message ON public.messages;
CREATE TRIGGER trg_update_chat_last_message
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_message_inserted();


-- =============================================================================
-- 3. VIEW: visible_incoming_requests
-- =============================================================================
-- One row per pending request sent TO the current user. Pre-joins the sender's
-- profile, primary photo, and human-readable labels so FlutterFlow can render
-- the "Request Received" card without follow-up queries.
-- =============================================================================

DROP VIEW IF EXISTS public.visible_incoming_requests;

CREATE VIEW public.visible_incoming_requests AS
SELECT
  -- Request identity
  request.id                                  AS request_id,
  request.created_at                          AS sent_at,
  request.brief_note                          AS request_note,

  -- Sender (the person who sent the request TO me)
  request.created_by                          AS sender_user_id,
  sender_profile.first_name                   AS sender_first_name,
  sender_profile.last_name                    AS sender_last_name,
  sender_profile.bio                          AS sender_bio,
  sender_profile.age_range                    AS sender_age_range_key,
  sender_age_setting.label                    AS sender_age_range_label,
  sender_profile.gender_identity              AS sender_gender_key,
  sender_gender_setting.label                 AS sender_gender_label,
  sender_profile.open_to                      AS sender_open_to,
  sender_photo.storage_path                   AS sender_photo_path

FROM public.connection_requests request

JOIN public.profiles sender_profile
  ON sender_profile.id         = request.created_by
  AND sender_profile.deleted_at IS NULL

LEFT JOIN public.profile_photos sender_photo
  ON sender_photo.profile_id    = request.created_by
  AND sender_photo.display_order = 1
  AND sender_photo.deleted_at    IS NULL

-- Look up the human-readable age-range label from app_settings JSONB.
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key        = 'age_range'
     AND setting_option->>'key' = sender_profile.age_range
   LIMIT 1
) sender_age_setting ON TRUE

-- Look up the human-readable gender-identity label from app_settings JSONB.
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key        = 'gender_identity'
     AND setting_option->>'key' = sender_profile.gender_identity
   LIMIT 1
) sender_gender_setting ON TRUE

WHERE request.deleted_at   IS NULL
  AND request.recipient_id = auth.uid()
  AND request.status       = 'pending'
  -- Exclude blocked senders (either direction).
  AND NOT EXISTS (
    SELECT 1
      FROM public.user_blocks existing_block
     WHERE (existing_block.created_by = auth.uid()           AND existing_block.blocked_user_id = request.created_by)
        OR (existing_block.created_by = request.created_by   AND existing_block.blocked_user_id = auth.uid())
  );

ALTER VIEW public.visible_incoming_requests SET (security_invoker = true);

GRANT SELECT ON public.visible_incoming_requests TO authenticated;
