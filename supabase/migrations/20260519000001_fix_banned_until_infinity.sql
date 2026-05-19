-- =============================================================================
-- Almost App — Fix banned_until = 'infinity' breaking auth
-- Generated: 2026-05-19
-- =============================================================================
-- delete_my_account() set auth.users.banned_until = 'infinity'. PostgreSQL
-- accepts that, but Supabase Auth (GoTrue) cannot deserialize the special
-- 'infinity' timestamp when it reads the user row during sign-in / schema
-- queries — every affected request then fails with the generic
-- "Database error querying schema" (code: unexpected_failure).
--
-- A permanent ban must use a FINITE far-future timestamp instead. GoTrue
-- parses that fine (it's how normal time-boxed bans already work).
--
-- Two parts:
--   1. Repair any rows already poisoned with 'infinity'.
--   2. Rewrite delete_my_account() to use a finite sentinel.
-- =============================================================================

BEGIN;

-- Sentinel for "permanently banned / account deleted". Far enough in the
-- future to be effectively permanent, but a real finite timestamp GoTrue
-- can read.
--   '9999-12-31 23:59:59+00'

-- -----------------------------------------------------------------------------
-- 1. Repair already-poisoned rows (the test deletes done before this fix)
-- -----------------------------------------------------------------------------
UPDATE auth.users
   SET banned_until = '9999-12-31 23:59:59+00'::timestamptz
 WHERE banned_until = 'infinity'::timestamptz;

-- -----------------------------------------------------------------------------
-- 2. Rewrite delete_my_account() to use the finite sentinel
-- -----------------------------------------------------------------------------
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

  -- 1. Anonymize + soft-delete the profile (only if not already deleted).
  UPDATE public.profiles
     SET deleted_at = now()
   WHERE id         = v_uid
     AND deleted_at IS NULL;

  -- 2. Permanently ban the auth identity with a FINITE far-future timestamp
  --    ('infinity' breaks GoTrue's auth queries). Email is retained on the
  --    row on purpose → same address can never sign up again.
  UPDATE auth.users
     SET banned_until = '9999-12-31 23:59:59+00'::timestamptz
   WHERE id = v_uid;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_my_account() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

COMMIT;
