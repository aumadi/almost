-- =============================================================================
-- Almost App — My Trips Display View
-- Generated: 2026-04-24
-- =============================================================================
-- Read-optimized view for the Trips screen. One row per trip owned by the
-- current user with airport codes + cities pre-joined, plus an overlap summary:
--
--   overlap_count          — total distinct users crossing paths with this trip
--   overlap_users_preview  — JSONB array of up to 5 most-recent overlapping
--                            users, each with {user_id, first_name, photo_path}
--
-- Upcoming / Past tab filtering is done by the caller (FlutterFlow) via
-- arrival_date >= CURRENT_DATE (Upcoming) or arrival_date < CURRENT_DATE (Past).
-- The view itself is tab-agnostic.
-- =============================================================================

DROP VIEW IF EXISTS public.visible_my_trips;

CREATE VIEW public.visible_my_trips AS
SELECT
  -- Trip identity (2)
  trip.id            AS trip_id,
  trip.created_at    AS created_at,

  -- Dates (3)
  trip.departure_date,
  trip.layover_date,
  trip.arrival_date,

  -- Intents (1)
  trip.connection_type AS intents,

  -- Departure airport (2)
  departure_airport.iata_code AS departure_iata,
  departure_airport.city      AS departure_city,

  -- Layover airport — nullable (2)
  layover_airport.iata_code   AS layover_iata,
  layover_airport.city        AS layover_city,

  -- Arrival airport (2)
  arrival_airport.iata_code   AS arrival_iata,
  arrival_airport.city        AS arrival_city,

  -- Overlap summary (2)
  overlap_summary.total_count AS overlap_count,
  overlap_summary.preview     AS overlap_users_preview

FROM public.trips trip

JOIN public.airports departure_airport
  ON departure_airport.id = trip.departure_airport_id

LEFT JOIN public.airports layover_airport
  ON layover_airport.id = trip.layover_airport_id

JOIN public.airports arrival_airport
  ON arrival_airport.id = trip.arrival_airport_id

-- Compute overlap count + preview in a single LATERAL.
-- Deduplicates by user first (one trip can match the same user at multiple
-- airports), then filters out soft-deleted profiles and blocked pairs, then
-- aggregates the visible users into count + top-5 preview ordered by recency.
LEFT JOIN LATERAL (
  WITH distinct_other_users AS (
    SELECT
      CASE WHEN overlap.user_a_id = trip.created_by
           THEN overlap.user_b_id
           ELSE overlap.user_a_id
      END                      AS other_user_id,
      MAX(overlap.created_at)  AS latest_overlap
    FROM public.trip_overlaps overlap
    WHERE (overlap.trip_a_id = trip.id OR overlap.trip_b_id = trip.id)
      AND overlap.deleted_at IS NULL
    GROUP BY
      CASE WHEN overlap.user_a_id = trip.created_by
           THEN overlap.user_b_id
           ELSE overlap.user_a_id
      END
  ),
  visible_other_users AS (
    SELECT
      du.other_user_id,
      du.latest_overlap,
      other_profile.first_name,
      other_photo.storage_path AS photo_path
    FROM distinct_other_users du
    JOIN public.profiles other_profile
      ON other_profile.id         = du.other_user_id
      AND other_profile.deleted_at IS NULL
    LEFT JOIN public.profile_photos other_photo
      ON other_photo.profile_id    = du.other_user_id
      AND other_photo.display_order = 1
      AND other_photo.deleted_at   IS NULL
    WHERE NOT EXISTS (
      SELECT 1 FROM public.user_blocks existing_block
      WHERE (existing_block.created_by      = auth.uid()         AND existing_block.blocked_user_id = du.other_user_id)
         OR (existing_block.blocked_user_id = auth.uid()         AND existing_block.created_by      = du.other_user_id)
    )
  )
  SELECT
    COUNT(*)::int AS total_count,
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'user_id',    top_user.other_user_id,
            'first_name', top_user.first_name,
            'photo_path', top_user.photo_path
          )
          ORDER BY top_user.latest_overlap DESC
        )
        FROM (
          SELECT *
          FROM visible_other_users
          ORDER BY latest_overlap DESC
          LIMIT 5
        ) top_user
      ),
      '[]'::jsonb
    ) AS preview
  FROM visible_other_users
) overlap_summary ON TRUE

WHERE trip.created_by  = auth.uid()
  AND trip.deleted_at IS NULL;


-- RLS of underlying tables applies to the caller (not the view owner).
ALTER VIEW public.visible_my_trips SET (security_invoker = true);

-- Expose to authenticated users.
GRANT SELECT ON public.visible_my_trips TO authenticated;
