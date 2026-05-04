-- =============================================================================
-- Almost App — Fix declined-filter NULL handling in visible_crossed_paths
-- Generated: 2026-04-29
-- =============================================================================
-- Bug introduced by 20260429000001: when no connection_request exists between
-- the pair, cr_latest.status is NULL. The previous WHERE used:
--
--   NOT (cr_latest.status = 'declined' AND ...)
--
-- which evaluates to NULL when status is NULL, and Postgres treats NULL in a
-- WHERE clause as false → the row is filtered OUT. Result: any overlap with
-- no existing request was hidden.
--
-- Fix: rewrite using IS DISTINCT FROM (NULL-safe inequality) so a missing
-- request keeps the row visible:
--
--   WHERE cr_latest.status IS DISTINCT FROM 'declined'
--      OR cr_latest.created_by = auth.uid()
--
-- Behavior table:
--   no request               → show (NULL IS DISTINCT FROM 'declined' = TRUE)
--   pending / accepted       → show
--   declined, I sent         → show (with "Declined" UI state)
--   declined, other sent     → hide  (I declined them — cleaned from the list)
-- =============================================================================

DROP VIEW IF EXISTS public.visible_crossed_paths;

CREATE VIEW public.visible_crossed_paths AS
WITH resolved AS (
  SELECT
    o.id                                                                        AS overlap_id,
    o.overlap_date,
    o.connection_type                                                           AS shared_intents,
    o.created_at                                                                AS matched_at,
    o.matched_airport_id,
    CASE WHEN o.user_a_id = auth.uid() THEN o.trip_a_id  ELSE o.trip_b_id  END  AS overlap_trip_id,
    CASE WHEN o.user_a_id = auth.uid() THEN o.user_b_id  ELSE o.user_a_id  END  AS other_user_id,
    CASE WHEN o.user_a_id = auth.uid() THEN o.trip_b_id  ELSE o.trip_a_id  END  AS other_trip_id
  FROM public.trip_overlaps o
  WHERE o.deleted_at IS NULL
    AND (o.user_a_id = auth.uid() OR o.user_b_id = auth.uid())
    AND NOT EXISTS (
      SELECT 1
        FROM public.user_blocks ub
       WHERE (ub.created_by = o.user_a_id AND ub.blocked_user_id = o.user_b_id)
          OR (ub.created_by = o.user_b_id AND ub.blocked_user_id = o.user_a_id)
    )
)
SELECT
  -- Overlap identity (4)
  r.overlap_id,
  r.overlap_date,
  r.shared_intents,
  r.matched_at,

  -- Overlap context (5)
  r.overlap_trip_id,
  r.matched_airport_id                      AS overlap_airport_id,
  ap_match.iata_code                        AS overlap_airport_iata,
  ap_match.city                             AS overlap_airport_city,
  CASE
    WHEN t_me.departure_airport_id = r.matched_airport_id
         AND t_me.departure_date   = r.overlap_date  THEN 'departure'
    WHEN t_me.layover_airport_id   = r.matched_airport_id
         AND t_me.layover_date     = r.overlap_date  THEN 'layover'
    WHEN t_me.arrival_airport_id   = r.matched_airport_id
         AND t_me.arrival_date     = r.overlap_date  THEN 'arrival'
  END                                       AS overlap_type,

  -- Other user (10)
  r.other_user_id,
  p_other.first_name                        AS other_first_name,
  p_other.last_name                         AS other_last_name,
  p_other.bio                               AS other_bio,
  p_other.age_range                         AS other_age_range_key,
  age_label.label                           AS other_age_range_label,
  p_other.gender_identity                   AS other_gender_key,
  gender_label.label                        AS other_gender_label,
  p_other.open_to                           AS other_open_to,
  photo_other.storage_path                  AS other_photo_path,

  -- Other user's trip (5)
  r.other_trip_id,
  ap_oth_dep.iata_code                      AS other_trip_dep_iata,
  ap_oth_arr.iata_code                      AS other_trip_arr_iata,
  t_other.departure_date                    AS other_trip_dep_date,
  t_other.arrival_date                      AS other_trip_arr_date,

  -- Connect button state + note (3)
  cr_latest.status                          AS request_status_with_other,
  (cr_latest.created_by = auth.uid())       AS request_sent_by_me,
  cr_latest.brief_note                      AS request_note,

  -- Chat navigation (1)
  chat_with_other.id                        AS chat_id

FROM resolved r

JOIN public.trips t_me
  ON t_me.id = r.overlap_trip_id

JOIN public.airports ap_match
  ON ap_match.id = r.matched_airport_id

JOIN public.profiles p_other
  ON p_other.id         = r.other_user_id
  AND p_other.deleted_at IS NULL

LEFT JOIN public.profile_photos photo_other
  ON photo_other.profile_id     = r.other_user_id
  AND photo_other.display_order = 1
  AND photo_other.deleted_at    IS NULL

LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'age_range'
     AND setting_option->>'key'   = p_other.age_range
   LIMIT 1
) age_label ON TRUE

LEFT JOIN LATERAL (
  SELECT setting_option->>'label' AS label
    FROM public.app_settings setting,
         jsonb_array_elements(setting.value) setting_option
   WHERE setting.key              = 'gender_identity'
     AND setting_option->>'key'   = p_other.gender_identity
   LIMIT 1
) gender_label ON TRUE

JOIN public.trips t_other
  ON t_other.id         = r.other_trip_id
  AND t_other.deleted_at IS NULL

JOIN public.airports ap_oth_dep
  ON ap_oth_dep.id = t_other.departure_airport_id

JOIN public.airports ap_oth_arr
  ON ap_oth_arr.id = t_other.arrival_airport_id

LEFT JOIN LATERAL (
  SELECT cr.status, cr.created_by, cr.brief_note
    FROM public.connection_requests cr
   WHERE cr.deleted_at IS NULL
     AND (
          (cr.created_by = auth.uid()      AND cr.recipient_id = r.other_user_id)
       OR (cr.created_by = r.other_user_id AND cr.recipient_id = auth.uid())
     )
   ORDER BY
     CASE cr.status
       WHEN 'accepted' THEN 1
       WHEN 'pending'  THEN 2
       WHEN 'declined' THEN 3
     END
   LIMIT 1
) cr_latest ON TRUE

LEFT JOIN public.chats chat_with_other
  ON chat_with_other.user_a_id = LEAST(auth.uid(), r.other_user_id)
  AND chat_with_other.user_b_id = GREATEST(auth.uid(), r.other_user_id)
  AND chat_with_other.deleted_at IS NULL

-- NULL-safe filter: hide ONLY when a declined request exists AND the OTHER
-- user sent it. Rows with no request (NULL status) stay visible because
-- IS DISTINCT FROM treats NULL as "not equal" to 'declined'.
WHERE cr_latest.status IS DISTINCT FROM 'declined'
   OR cr_latest.created_by = auth.uid();


ALTER VIEW public.visible_crossed_paths SET (security_invoker = true);
GRANT SELECT ON public.visible_crossed_paths TO authenticated;
