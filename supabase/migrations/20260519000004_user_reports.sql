-- =============================================================================
-- Almost App — User reports (Safety Tools: Report)
-- Generated: 2026-05-19
-- =============================================================================
-- Per Feature Overview doc → Safety Tools section: users can BLOCK or
-- REPORT individuals who are disrespectful. Block already shipped in
-- 20260519000002. This migration adds the Report half:
--
--   • New table public.user_reports — one row per individual report.
--     Unlike user_blocks (one row per pair, lifetime UNIQUE), reports
--     can repeat: a pattern of behaviour matters and admins need full
--     history.
--   • RPC public.report_user(...) — single FlutterFlow entry point.
--     Inserts the report row and (by default) also inserts a user_blocks
--     row so the reporter doesn't have to file a separate block.
--   • RLS — reporter can read their own reports; can insert their own;
--     no UPDATE/DELETE for normal users (admins only, once that role
--     exists; admin reads/updates are intentionally NOT granted here).
--
-- Per product owner decision:
--   • NO server-side validation of reason_note length, reason_key
--     category, or rate limit. The FlutterFlow client enforces the
--     50-char minimum, max length, required category, etc. The server
--     only enforces basic authorization (caller must be authenticated;
--     cannot report self).
--   • Reports are silent — the reported user is never notified.
--   • Report ALWAYS bundles a block — there is no opt-out. Reporting
--     is the stricter action, so it implies a block by definition.
--     One action, one decision, no checkbox.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. user_reports table
-- =============================================================================
-- No UNIQUE constraint on (created_by, reported_user_id) — same person can
-- be reported multiple times by the same reporter over time (different
-- incidents). The admin queue / dashboard can dedupe for display.

CREATE TABLE IF NOT EXISTS public.user_reports (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,    -- reporter
  reported_user_id   uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reason_key         text,                                                                -- shares app_settings('block_reason') keys
  reason_note        text,
  context_chat_id    uuid        REFERENCES public.chats(id) ON DELETE SET NULL,          -- nullable; set when reported from a chat
  status             text        NOT NULL DEFAULT 'pending',                              -- 'pending' | 'reviewed' | 'actioned' | 'dismissed'
  reviewed_at        timestamptz,
  reviewed_by        uuid        REFERENCES auth.users(id) ON DELETE SET NULL,            -- admin user_id, once admin role exists
  action_taken       text                                                                 -- 'warn' | 'suspend' | 'ban' | 'none'
);

-- Indexes for the two main access patterns:
--   • admin queue:   pending reports, oldest first
--   • per-user view: my own reports
CREATE INDEX IF NOT EXISTS idx_user_reports_pending
  ON public.user_reports(created_at)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_user_reports_created_by
  ON public.user_reports(created_by, created_at DESC);


-- =============================================================================
-- 2. RLS
-- =============================================================================
-- Reporters can read and insert their own reports. No UPDATE/DELETE for
-- normal users. Admin-side policies are NOT created here — they belong in
-- a future migration that introduces an admin role marker.

ALTER TABLE public.user_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_reports_select_own
  ON public.user_reports FOR SELECT
  USING (created_by = auth.uid());

CREATE POLICY user_reports_insert_own
  ON public.user_reports FOR INSERT
  WITH CHECK (created_by = auth.uid());

-- No update/delete policies → only roles that bypass RLS (postgres /
-- supabase_admin / future admin role) can touch existing rows.


-- =============================================================================
-- 3. RPC: report_user
-- =============================================================================
-- One FlutterFlow call, optionally bundles the matching block. Returns
-- the user_reports.id so the client can show "Report #..." confirmations
-- if desired.
--
-- Authorization (NOT validation):
--   • auth.uid() must be set
--   • p_reported_user_id cannot equal auth.uid() (no self-report)
--
-- Input correctness (length, category, etc.) is the client's job.

CREATE OR REPLACE FUNCTION public.report_user(
  p_reported_user_id uuid,
  p_reason_key       text,
  p_reason_note      text,
  p_context_chat_id  uuid
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
    created_by, reported_user_id, reason_key, reason_note, context_chat_id
  )
  VALUES (
    v_uid, p_reported_user_id, p_reason_key, p_reason_note, p_context_chat_id
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

REVOKE EXECUTE ON FUNCTION public.report_user(uuid, text, text, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.report_user(uuid, text, text, uuid) TO authenticated;


COMMIT;
