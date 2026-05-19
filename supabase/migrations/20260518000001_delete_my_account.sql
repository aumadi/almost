-- =============================================================================
-- Almost App — Delete account (minimal: anonymize profile + ban auth row)
-- Generated: 2026-05-18
-- =============================================================================
-- Scope (intentionally minimal for now):
--   1. profiles.deleted_at = now()  → fires anonymize_profile_on_soft_delete
--      (name → "Deleted User", demographics nulled) and hides the profile
--      everywhere via the profiles_select_all RLS (deleted_at IS NULL).
--   2. auth.users.banned_until = 'infinity'  → the account can never
--      authenticate again. The real email is intentionally LEFT on the row,
--      so the UNIQUE email constraint permanently blocks that address from
--      ever registering again.
--
-- Everything else (trips, connection_requests, chats, notifications,
-- user_devices, profile_photos, Storage files) is deliberately left as-is
-- per current product decision. No email rename, no Storage deletion, no
-- Edge Function — a single SECURITY DEFINER RPC covers it.
--
-- NOTE: docs/privacy-policy.md §7 currently claims photos and content are
-- deleted. Reword that section before publishing so the policy matches this
-- retain-everything behaviour.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.delete_my_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 1. Anonymize + soft-delete the profile (only if not already deleted, so
  --    a double call doesn't re-fire the trigger).
  UPDATE public.profiles
     SET deleted_at = now()
   WHERE id         = v_uid
     AND deleted_at IS NULL;

  -- 2. Permanently ban the auth identity. Email retained on the row on
  --    purpose → same address can never sign up again.
  UPDATE auth.users
     SET banned_until = 'infinity'::timestamptz
   WHERE id = v_uid;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_my_account() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

COMMIT;
