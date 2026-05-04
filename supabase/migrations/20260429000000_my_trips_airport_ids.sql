-- =============================================================================
-- Almost App — visible_my_trips: add airport UUIDs and has_layover flag
-- Generated: 2026-04-29
-- =============================================================================
-- Adds 4 fields to visible_my_trips:
--
--   departure_airport_id  uuid     — FK reference to airports
--   layover_airport_id    uuid     — FK reference to airports (NULL if no layover)
--   arrival_airport_id    uuid     — FK reference to airports
--   has_layover           boolean  — true when this trip has a layover
--
-- The IATA codes and city names are still exposed for display; the UUIDs are
-- added for cases where FlutterFlow needs to link back to the airports table
-- (e.g. profile detail navigation, secondary lookups).
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

  -- Departure airport (3 — uuid + iata + city)
  departure_airport.id        AS departure_airport_id,
  departure_airport.iata_code AS departure_iata,
  departure_airport.city      AS departure_city,

  -- Layover airport — nullable (3 — uuid + iata + city)
  layover_airport.id          AS layover_airport_id,
  layover_airport.iata_code   AS layover_iata,
  layover_airport.city        AS layover_city,

  -- Arrival airport (3 — uuid + iata + city)
  arrival_airport.id          AS arrival_airport_id,
  arrival_airport.iata_code   AS arrival_iata,
  arrival_airport.city        AS arrival_city,

  -- Layover convenience flag (1)
  (trip.layover_airport_id IS NOT NULL) AS has_layover,

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


ALTER VIEW public.visible_my_trips SET (security_invoker = true);
GRANT SELECT ON public.visible_my_trips TO authenticated;
