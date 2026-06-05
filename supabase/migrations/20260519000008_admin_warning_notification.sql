-- =============================================================================
-- Almost App — Add 'admin_warning' to notification_type enum
-- Generated: 2026-05-19
-- =============================================================================
-- PostgreSQL gotcha: a newly-added enum value cannot be REFERENCED in the
-- same transaction that added it (error 55P04 "unsafe use of new value").
-- So this migration does ONLY the ALTER TYPE — nothing else. All
-- consumers of the new value (trigger function, view CASE branch, etc.)
-- live in 20260519000009 which runs after this migration commits.
-- =============================================================================

ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'admin_warning';
