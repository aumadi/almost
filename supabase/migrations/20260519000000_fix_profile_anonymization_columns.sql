-- =============================================================================
-- Almost App — Fix stale handle_profile_anonymization() column names
-- Generated: 2026-05-19
-- =============================================================================
-- The original anonymization trigger (20260406000000) nulls out UUID-FK
-- columns age_range_id / gender_identity_id / pronouns_id / education_id /
-- ethnicity_id. Migration 20260406000002 DROPPED those columns and replaced
-- them with plain text columns age_range / gender_identity / pronouns /
-- education / ethnicity — but this trigger function was never updated.
--
-- Result: any UPDATE that sets profiles.deleted_at (e.g. delete_my_account())
-- fails with: record "new" has no field "age_range_id" (SQLSTATE 42703).
--
-- This migration rewrites the function to scrub the CURRENT text columns.
-- The trigger itself (anonymize_profile_on_soft_delete) is unchanged.
-- =============================================================================

BEGIN;

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
  END IF;
  RETURN NEW;
END;
$$;

COMMIT;
