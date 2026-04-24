-- =============================================================================
-- Almost App — Link connect requests to their source overlap
-- Generated: 2026-04-24
-- =============================================================================
-- Adds an overlap_id FK column to connection_requests so each request knows
-- which Crossed Paths meeting it was triggered from. Updates
-- visible_incoming_requests to expose the meeting's airport, date, and
-- shared intents so the Request Received card can show that context.
--
-- Nullable FK with ON DELETE SET NULL — legacy requests (if any) have NULL,
-- and if a trip_overlaps row is ever hard-deleted, the request keeps existing
-- just without the context pointer.
-- =============================================================================


-- =============================================================================
-- 1. Add overlap_id column
-- =============================================================================

ALTER TABLE public.connection_requests
  ADD COLUMN IF NOT EXISTS overlap_id uuid
    REFERENCES public.trip_overlaps(id) ON DELETE SET NULL;

-- Index for the join in visible_incoming_requests.
CREATE INDEX IF NOT EXISTS idx_connection_requests_overlap_id
  ON public.connection_requests(overlap_id)
  WHERE deleted_at IS NULL AND overlap_id IS NOT NULL;


-- =============================================================================
-- 2. Recreate visible_incoming_requests with 5 new overlap-context fields
-- =============================================================================

DROP VIEW IF EXISTS public.visible_incoming_requests;

CREATE VIEW public.visible_incoming_requests AS
SELECT
  -- Request identity
  request.id                                  AS request_id,
  request.created_at                          AS sent_at,
  request.brief_note                          AS request_note,

  -- Sender (the person who sent the request TO me)
  request.created_by                          AS sender_user_id,
  sender_profile.first_name                   AS sender_first_name,
  sender_profile.last_name                    AS sender_last_name,
  sender_profile.bio                          AS sender_bio,
  sender_profile.age_range                    AS sender_age_range_key,
  sender_age_setting.label                    AS sender_age_range_label,
  sender_profile.gender_identity              AS sender_gender_key,
  sender_gender_setting.label                 AS sender_gender_label,
  sender_profile.open_to                      AS sender_open_to,
  sender_photo.storage_path                   AS sender_photo_path,

  -- Overlap context — the Crossed Paths meeting that triggered the request.
  -- Fields are NULL if overlap_id is NULL or the overlap was soft-deleted
  -- (e.g. the sender later edited their trip).
  request.overlap_id                          AS request_overlap_id,
  overlap_airport.iata_code                   AS request_overlap_airport_iata,
  overlap_airport.city                        AS request_overlap_airport_city,
  source_overlap.overlap_date                 AS request_overlap_date,
  source_overlap.connection_type              AS request_shared_intents

FROM public.connection_requests request

JOIN public.profiles sender_profile
  ON sender_profile.id          = request.created_by
  AND sender_profile.deleted_at IS NULL

LEFT JOIN public.profile_photos sender_photo
  ON sender_photo.profile_id     = request.created_by
  AND sender_photo.display_order = 1
  AND sender_photo.deleted_at    IS NULL

-- Look up the human-readable age-range label from app_settings JSONB.
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'age_range'
     AND setting_option->>'key'   = sender_profile.age_range
   LIMIT 1
) sender_age_setting ON TRUE

-- Look up the human-readable gender-identity label from app_settings JSONB.
LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'gender_identity'
     AND setting_option->>'key'   = sender_profile.gender_identity
   LIMIT 1
) sender_gender_setting ON TRUE

-- Overlap context: LEFT JOIN because overlap_id can be NULL, and because
-- trip_overlaps RLS filters soft-deleted rows (yields NULLs after a trip edit).
LEFT JOIN public.trip_overlaps source_overlap
  ON source_overlap.id = request.overlap_id

LEFT JOIN public.airports overlap_airport
  ON overlap_airport.id = source_overlap.matched_airport_id

WHERE request.deleted_at   IS NULL
  AND request.recipient_id = auth.uid()
  AND request.status       = 'pending'
  -- Exclude blocked senders (either direction).
  AND NOT EXISTS (
    SELECT 1
      FROM public.user_blocks existing_block
     WHERE (existing_block.created_by = auth.uid()           AND existing_block.blocked_user_id = request.created_by)
        OR (existing_block.created_by = request.created_by   AND existing_block.blocked_user_id = auth.uid())
  );

ALTER VIEW public.visible_incoming_requests SET (security_invoker = true);

GRANT SELECT ON public.visible_incoming_requests TO authenticated;
