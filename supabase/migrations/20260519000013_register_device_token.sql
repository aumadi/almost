+-- =============================================================================
-- Almost App — FCM device-token dedup at the DB layer
-- Generated: 2026-05-19
-- =============================================================================
-- FlutterFlow already inserts into public.user_devices on every app
-- launch. Today that breaks with a UNIQUE-violation when the same
-- phone is signed in by a second user (token was already registered to
-- user A). The fix is fully server-side — no FlutterFlow code changes:
--
--   1. Replace the strict UNIQUE(fcm_token) with a PARTIAL UNIQUE INDEX
--      that only enforces uniqueness across ACTIVE rows
--      (deleted_at IS NULL). Soft-deleted rows keep history.
--
--   2. Add a BEFORE INSERT trigger on public.user_devices that:
--        Case A — same (user_id, fcm_token) already active:
--            refresh platform + last_active_at on the existing row,
--            return NULL to skip the actual INSERT (no-op from FF's
--            view — succeeds, no duplicate key error).
--
--        Case B — fcm_token is active under a DIFFERENT user:
--            soft-delete that user's row (the previous owner of this
--            phone has signed out), then proceed with the INSERT for
--            the current user. The partial unique index now permits it.
--
--        Case C — no active row exists for this token at all:
--            proceed with the INSERT untouched.
--
-- Net effect: FlutterFlow keeps doing what it does today. The trigger
-- transparently makes every insert succeed (or no-op) with the token
-- correctly attached to whoever just signed in.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Replace strict UNIQUE constraint with partial unique index
-- =============================================================================

ALTER TABLE public.user_devices
  DROP CONSTRAINT IF EXISTS user_devices_fcm_token_key;

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_devices_fcm_token_active
  ON public.user_devices(fcm_token)
  WHERE deleted_at IS NULL;


-- =============================================================================
-- 2. BEFORE INSERT dedup trigger
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_user_device_token_dedupe()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Case A: same user already has this token active → refresh + no-op.
  UPDATE public.user_devices
     SET platform       = NEW.platform,
         last_active_at = now(),
         updated_at     = now()
   WHERE user_id    = NEW.user_id
     AND fcm_token  = NEW.fcm_token
     AND deleted_at IS NULL;

  IF FOUND THEN
    -- Skip the actual INSERT — row already exists for this user/token.
    RETURN NULL;
  END IF;

  -- Case B: another user holds this token actively → soft-delete it
  --         so the partial unique index permits the new insert.
  UPDATE public.user_devices
     SET deleted_at = now()
   WHERE fcm_token  = NEW.fcm_token
     AND user_id   <> NEW.user_id
     AND deleted_at IS NULL;

  -- Case C (and the tail of Case B): proceed with the INSERT as-is.
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_handle_user_device_token_dedupe ON public.user_devices;
CREATE TRIGGER trg_handle_user_device_token_dedupe
  BEFORE INSERT ON public.user_devices
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_user_device_token_dedupe();


COMMIT;
