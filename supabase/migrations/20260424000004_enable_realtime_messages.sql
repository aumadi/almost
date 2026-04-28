-- =============================================================================
-- Almost App — Enable Realtime on messages
-- Generated: 2026-04-24
-- =============================================================================
-- Adds public.messages to the supabase_realtime publication so FlutterFlow
-- can subscribe to INSERTs (new messages) and UPDATEs (is_read toggles) in
-- real time on the Chat Detail screen.
--
-- REPLICA IDENTITY FULL is set so Realtime events include the full old row
-- on UPDATE / DELETE events — needed if you want to observe is_read flips.
--
-- Idempotent: safe to re-run. The DO block skips adding the table to the
-- publication if it's already there.
-- =============================================================================

-- Let Realtime see the full row on UPDATE/DELETE events.
ALTER TABLE public.messages REPLICA IDENTITY FULL;

-- Add messages to the supabase_realtime publication (skip if already added).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_publication_tables
     WHERE pubname    = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename  = 'messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
  END IF;
END $$;
