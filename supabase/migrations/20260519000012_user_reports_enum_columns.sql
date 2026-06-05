-- =============================================================================
-- Almost App — Convert user_reports.status and action_taken to enums
-- Generated: 2026-05-19
-- =============================================================================
-- The two state columns on user_reports were created as text with allowed
-- values documented in comments only. Promoting them to proper enums:
--
--   • Postgres rejects invalid values at insert/update time (no typos).
--   • Future admin RPCs and dashboard code get autocomplete / type-safe
--     reads without separate validation lookups.
--   • Schema self-documents the allowed lifecycle states.
--
-- Enum definitions:
--
--   user_report_status
--     'pending'    — newly filed, not yet reviewed
--     'reviewed'   — admin has looked at it but hasn't actioned yet
--     'actioned'   — admin took an action (see action_taken)
--     'dismissed'  — admin reviewed and decided no action is needed
--
--   user_report_action
--     'none'       — admin actively decided no action (distinct from NULL = not yet decided)
--     'warn'       — warning notification fires to reported user
--     'suspend'    — temporary ban
--     'ban'        — permanent ban
--
-- Existing rows (only the 'pending' default; no real reports yet) convert
-- cleanly via USING-casts. The warning trigger from 20260519000009 is
-- dropped and recreated after the column type change so its WHEN clause
-- is reparsed against the new enum type.
-- =============================================================================

BEGIN;


-- =============================================================================
-- 1. Create the enum types
-- =============================================================================

CREATE TYPE public.user_report_status AS ENUM (
  'pending',
  'reviewed',
  'actioned',
  'dismissed'
);

CREATE TYPE public.user_report_action AS ENUM (
  'none',
  'warn',
  'suspend',
  'ban'
);


-- =============================================================================
-- 2. Drop dependents that reference status as text
-- =============================================================================
-- The partial index idx_user_reports_pending has predicate
-- `WHERE status = 'pending'` — once the column becomes enum, Postgres
-- cannot re-validate that predicate without a text↔enum operator. Drop
-- it now and recreate it after the column-type change.
--
-- The warning trigger's WHEN clause references action_taken (rebuilt
-- below). Drop here so it gets re-parsed against the new enum type.

DROP INDEX  IF EXISTS public.idx_user_reports_pending;
DROP TRIGGER IF EXISTS trg_fire_admin_warning_notification ON public.user_reports;


-- =============================================================================
-- 3. Convert user_reports.status to enum
-- =============================================================================

ALTER TABLE public.user_reports
  ALTER COLUMN status DROP DEFAULT;

ALTER TABLE public.user_reports
  ALTER COLUMN status TYPE public.user_report_status
  USING status::public.user_report_status;

ALTER TABLE public.user_reports
  ALTER COLUMN status SET DEFAULT 'pending'::public.user_report_status;


-- =============================================================================
-- 4. Convert user_reports.action_taken to enum
-- =============================================================================
-- Nullable column; NULL values pass through unchanged. Any existing 'warn'
-- / 'suspend' / 'ban' / 'none' values cast cleanly.

ALTER TABLE public.user_reports
  ALTER COLUMN action_taken TYPE public.user_report_action
  USING action_taken::public.user_report_action;


-- =============================================================================
-- 5. Recreate the partial index against the new enum type
-- =============================================================================
-- Same predicate as before; 'pending' is now parsed as the enum value.

CREATE INDEX IF NOT EXISTS idx_user_reports_pending
  ON public.user_reports(created_at)
  WHERE status = 'pending'::public.user_report_status;


-- =============================================================================
-- 6. Recreate the warning trigger
-- =============================================================================
-- The function body uses NEW.reason_key (still text) and inserts into
-- notifications.body — nothing in it cares about the action_taken column
-- type. Only the WHEN clause references action_taken; recreating the
-- trigger reparses it under the new enum type.

CREATE TRIGGER trg_fire_admin_warning_notification
  AFTER UPDATE ON public.user_reports
  FOR EACH ROW
  WHEN (NEW.action_taken = 'warn' AND OLD.action_taken IS DISTINCT FROM 'warn')
  EXECUTE FUNCTION public.fire_admin_warning_notification();


COMMIT;
