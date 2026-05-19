-- =============================================================================
-- Almost App — Monthly connection-request limit
-- Generated: 2026-05-18
-- =============================================================================
-- A user may initiate at most N connection requests per CALENDAR MONTH
-- (UTC boundary). N is configured in app_settings so it can be changed with
-- a single UPDATE, no redeploy. Default N = 3.
--
-- Same-person re-requests are already capped at 1 lifetime by the existing
-- UNIQUE(created_by, recipient_id) constraint, so this cap only controls how
-- many DIFFERENT people a user can reach out to per month.
--
-- Counting rule: every request the user created since the 1st of the current
-- month counts — regardless of status (pending/accepted/declined) or
-- deleted_at. There is no "unsend", so a created request always exists; the
-- cap is purely about breadth of outreach.
--
-- Three parts:
--   1. Seed app_settings row  key='limits'
--   2. BEFORE INSERT trigger on connection_requests (server-side enforcement)
--   3. my_connection_request_quota() RPC (UI read model: used/limit/
--      remaining/resets_on)
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Config row in app_settings
-- =============================================================================
-- app_settings is key (text PK) -> value (jsonb). One 'limits' row holds all
-- numeric caps so future limits live in the same place.

INSERT INTO public.app_settings (key, value)
VALUES ('limits', '{"monthly_connection_requests": 3}'::jsonb)
ON CONFLICT (key) DO UPDATE
  SET value = public.app_settings.value || EXCLUDED.value;
-- (|| merges keys: keeps any other limits already present, sets/overwrites
--  monthly_connection_requests.)


-- =============================================================================
-- 2. Enforcement trigger
-- =============================================================================
-- BEFORE INSERT so we reject before the row exists. SECURITY DEFINER +
-- search_path='' so the count sees ALL of the user's rows (including
-- soft-deleted) and is not narrowed by RLS — keeps it consistent with the
-- quota RPC below.

CREATE OR REPLACE FUNCTION public.enforce_monthly_connection_request_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit       int;
  v_used        int;
  v_resets_on   date;
BEGIN
  -- Configured cap; default to 3 if the row/key is missing.
  SELECT COALESCE((s.value ->> 'monthly_connection_requests')::int, 3)
    INTO v_limit
    FROM public.app_settings s
   WHERE s.key = 'limits';

  v_limit := COALESCE(v_limit, 3);

  -- Requests this calendar month (UTC), by this user, all statuses.
  SELECT count(*)
    INTO v_used
    FROM public.connection_requests cr
   WHERE cr.created_by = NEW.created_by
     AND cr.created_at >= date_trunc('month', now());

  IF v_used >= v_limit THEN
    v_resets_on := (date_trunc('month', now()) + interval '1 month')::date;
    RAISE EXCEPTION
      'You have reached your limit of % connection requests this month. It resets on %.',
      v_limit, to_char(v_resets_on, 'FMDD Mon YYYY')
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.enforce_monthly_connection_request_limit() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.enforce_monthly_connection_request_limit() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_enforce_monthly_connection_request_limit
  ON public.connection_requests;

CREATE TRIGGER trg_enforce_monthly_connection_request_limit
  BEFORE INSERT ON public.connection_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_monthly_connection_request_limit();


-- =============================================================================
-- 3. UI read model
-- =============================================================================
-- Returns one row the client binds directly:
--   limit_count  — configured cap
--   used_count   — requests created this month by the caller
--   remaining    — GREATEST(0, limit - used)
--   resets_on    — first day of next month (so the UI needs no date math)
--
-- SECURITY DEFINER so the count matches the trigger exactly (counts all rows,
-- including soft-deleted, not narrowed by RLS). Scoped to auth.uid() so a
-- caller only ever sees their own quota.

CREATE OR REPLACE FUNCTION public.my_connection_request_quota()
RETURNS TABLE (
  limit_count int,
  used_count  int,
  remaining   int,
  resets_on   date
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_limit int;
  v_used  int;
BEGIN
  SELECT COALESCE((s.value ->> 'monthly_connection_requests')::int, 3)
    INTO v_limit
    FROM public.app_settings s
   WHERE s.key = 'limits';

  v_limit := COALESCE(v_limit, 3);

  SELECT count(*)
    INTO v_used
    FROM public.connection_requests cr
   WHERE cr.created_by = v_uid
     AND cr.created_at >= date_trunc('month', now());

  limit_count := v_limit;
  used_count  := v_used;
  remaining   := GREATEST(0, v_limit - v_used);
  resets_on   := (date_trunc('month', now()) + interval '1 month')::date;
  RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.my_connection_request_quota() TO authenticated;


COMMIT;
