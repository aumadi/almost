-- =============================================================================
-- Almost App — user_blocks RLS: symmetric visibility so inline filters work
-- Generated: 2026-05-19
-- =============================================================================
-- The block filter implemented in 20260519000002 fails on the blocked
-- user's side because every inline `NOT EXISTS user_blocks` check inside
-- a security_invoker view (or in an RLS policy) runs with the calling
-- user's privileges. The previous user_blocks_select_own policy only let
-- the BLOCKER read their own block rows:
--
--   USING (created_by = auth.uid())
--
-- So when the blocked user (Demo) queries visible_crossed_paths, the
-- NOT EXISTS subquery searching for a block row where
--   (created_by=Tushal AND blocked_user_id=Demo)
-- returns ZERO rows because Demo can't see rows created by Tushal. The
-- NOT EXISTS evaluates TRUE, the filter doesn't fire, Demo still sees
-- Tushal in every list.
--
-- This migration widens the SELECT policy so a user_blocks row is
-- visible to BOTH the blocker (created_by) AND the blocked party
-- (blocked_user_id). With the row visible from either side, every
-- inline NOT EXISTS check already in the views/policies starts working
-- symmetrically — no view or policy rewrites required.
--
-- Trade-off (documented honestly): a blocked user can now query
-- user_blocks directly and discover that they have been blocked (and by
-- whom). In practice the FlutterFlow client doesn't expose blocks as a
-- queryable surface to end users, so this leak is theoretical unless a
-- screen is built that queries the table directly. We're accepting that
-- trade-off because the alternative is a SECURITY DEFINER helper which
-- the product owner has chosen not to introduce.
--
-- INSERT/UPDATE/DELETE policies are unchanged — only the blocker can
-- still create or remove their own block rows.
-- =============================================================================

BEGIN;

DROP POLICY IF EXISTS user_blocks_select_own ON public.user_blocks;

CREATE POLICY user_blocks_select_own
  ON public.user_blocks FOR SELECT
  USING (
    created_by      = auth.uid()
    OR blocked_user_id = auth.uid()
  );

COMMIT;
