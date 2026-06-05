-- =============================================================================
-- Almost App — Drop user_reports.context_chat_id
-- Generated: 2026-05-19
-- =============================================================================
-- 20260519000004 stored a context_chat_id on each report so the admin could
-- jump straight into the conversation the complaint referenced. The chat
-- between any pair of users is already derivable via the chats unique-pair
-- constraint:
--
--   SELECT id FROM public.chats
--    WHERE (user_a_id = report.created_by      AND user_b_id = report.reported_user_id)
--       OR (user_a_id = report.reported_user_id AND user_b_id = report.created_by);
--
-- So the column is redundant — admins can resolve the chat at review time
-- without the report carrying its id. Removing it simplifies both the
-- table and the RPC.
--
-- Two changes:
--   1. Drop the context_chat_id column.
--   2. Recreate report_user() with a 3-argument signature (no
--      p_context_chat_id). The old 4-arg version is dropped explicitly so
--      both signatures don't co-exist.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Drop the column
-- =============================================================================

ALTER TABLE public.user_reports
  DROP COLUMN IF EXISTS context_chat_id;


-- =============================================================================
-- 2. Recreate report_user() without the p_context_chat_id parameter
-- =============================================================================
-- Drop the old 4-arg signature explicitly. Postgres treats functions with
-- different argument lists as distinct, so without an explicit DROP the
-- old version would linger and the FlutterFlow client could call either.

DROP FUNCTION IF EXISTS public.report_user(uuid, text, text, uuid);

CREATE OR REPLACE FUNCTION public.report_user(
  p_reported_user_id uuid,
  p_reason_key       text,
  p_reason_note      text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_report_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_reported_user_id IS NULL OR p_reported_user_id = v_uid THEN
    RAISE EXCEPTION 'Invalid report target'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 1. Insert the report row (one per incident; no UNIQUE).
  INSERT INTO public.user_reports (
    created_by, reported_user_id, reason_key, reason_note
  )
  VALUES (
    v_uid, p_reported_user_id, p_reason_key, p_reason_note
  )
  RETURNING id INTO v_report_id;

  -- 2. Report ALWAYS bundles a block — no opt-out. Idempotent: if the
  --    reporter already blocked this user, refresh reason_key/note.
  INSERT INTO public.user_blocks (
    created_by, blocked_user_id, reason_key, reason_note
  )
  VALUES (v_uid, p_reported_user_id, p_reason_key, p_reason_note)
  ON CONFLICT (created_by, blocked_user_id) DO UPDATE
     SET reason_key  = COALESCE(EXCLUDED.reason_key,  public.user_blocks.reason_key),
         reason_note = COALESCE(EXCLUDED.reason_note, public.user_blocks.reason_note);

  RETURN v_report_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.report_user(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.report_user(uuid, text, text) TO authenticated;


COMMIT;
