-- =============================================================================
-- Almost App — Add is_admin column to profiles
-- Generated: 2026-05-19
-- =============================================================================
-- Per product owner: track admin status as a single boolean directly on
-- profiles rather than a separate admin_users table. Every existing user
-- gets is_admin = false by default; the very first admin is bootstrapped
-- with a SQL UPDATE from the SQL Editor (which runs as postgres / no
-- auth.uid(), and so bypasses the self-promotion guard below).
--
-- TWO guardrails are essential because of two existing RLS facts:
--
--   1. profiles_update_own lets a user UPDATE their own row. Without
--      a trigger, anyone could flip is_admin = true on themselves and
--      grant themselves admin powers. Migration #2 below adds a
--      BEFORE UPDATE trigger that rejects is_admin changes unless the
--      caller is already an admin (or auth.uid() is NULL, i.e. running
--      from a privileged DB session for bootstrap).
--
--   2. profiles_select_all lets any authenticated user read every
--      non-deleted profile, INCLUDING is_admin. So in this design,
--      admin status is publicly visible to other users. That trade-off
--      is accepted in exchange for the simpler single-column approach.
--      If admin status must be hidden later, either: (a) move admin
--      reads behind a SECURITY DEFINER RPC, or (b) switch to a
--      separate admin_users table with RLS.
--
-- Anonymization trigger is also updated so that soft-deleting an
-- admin's account (via delete_my_account()) clears their admin flag —
-- a deleted account should not retain admin powers.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Add the column (every existing user picks up default false)
-- =============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;


-- =============================================================================
-- 2. Self-promotion guard
-- =============================================================================
-- BEFORE UPDATE trigger that allows is_admin changes only when:
--   a) running from a privileged DB session (auth.uid() IS NULL — SQL
--      Editor as postgres / dashboard table editor), OR
--   b) the caller is currently an admin themselves.
--
-- This closes the self-promote-to-admin vulnerability that would
-- otherwise exist via the profiles_update_own RLS policy.

CREATE OR REPLACE FUNCTION public.prevent_non_admin_is_admin_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.is_admin IS DISTINCT FROM OLD.is_admin THEN
    -- Bootstrap path: SQL Editor / postgres role / dashboard.
    IF auth.uid() IS NULL THEN
      RETURN NEW;
    END IF;

    -- Otherwise the caller must already be an admin.
    IF NOT EXISTS (
      SELECT 1
        FROM public.profiles caller_profile
       WHERE caller_profile.id       = auth.uid()
         AND caller_profile.is_admin = true
    ) THEN
      RAISE EXCEPTION 'Only admins can change is_admin'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_non_admin_is_admin_change ON public.profiles;
CREATE TRIGGER prevent_non_admin_is_admin_change
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_non_admin_is_admin_change();


-- =============================================================================
-- 3. Anonymization trigger — also revoke is_admin on soft-delete
-- =============================================================================
-- Otherwise a deleted (banned) account would keep its admin flag, which
-- is undesirable and could be surprising during incident review.

CREATE OR REPLACE FUNCTION public.handle_profile_anonymization()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
    NEW.first_name       := 'Deleted';
    NEW.last_name        := 'User';
    NEW.bio              := NULL;
    NEW.height_cm        := NULL;
    NEW.age_range        := NULL;
    NEW.gender_identity  := NULL;
    NEW.pronouns         := NULL;
    NEW.education        := NULL;
    NEW.ethnicity        := NULL;
    NEW.open_to          := NULL;
    NEW.profile_complete := false;
    NEW.is_admin         := false;  -- revoke admin on soft-delete
  END IF;
  RETURN NEW;
END;
$$;


COMMIT;
