-- =============================================================================
-- Almost App — Add new_crossed_path and crossed_paths_summary enum values
-- Generated: 2026-06-23
-- =============================================================================
-- PostgreSQL gotcha: newly-added enum values cannot be REFERENCED in the
-- same transaction. So this migration does ONLY the ALTER TYPE — nothing
-- else. All consumers (trigger inside compute_overlaps_for_trip_v2,
-- visible_notifications display branch, Edge Function payload builder)
-- live in 20260623000001 which runs after this commits.
-- =============================================================================

ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'new_crossed_path';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'crossed_paths_summary';
