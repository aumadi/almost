-- =============================================================================
-- Almost App — Initial Schema Migration
-- Generated: 2026-04-06
-- =============================================================================
-- Stack: FlutterFlow (frontend) + Supabase (backend)
-- Run via: supabase db push  OR  paste into Supabase SQL Editor
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. EXTENSIONS
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid() fallback (Supabase has it via pg_crypto)
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- future full-text / trigram search on airports


-- =============================================================================
-- 2. ENUM TYPES
-- =============================================================================

CREATE TYPE public.connection_type AS ENUM (
  'romantic',
  'platonic',
  'professional'
);

CREATE TYPE public.connection_request_status AS ENUM (
  'pending',
  'accepted',
  'declined'
);

CREATE TYPE public.notification_type AS ENUM (
  'connection_request_received',
  'connection_accepted',
  'new_message',
  'trip_starts_tomorrow'
);

CREATE TYPE public.open_to AS ENUM (
  'men',
  'women',
  'both'
);


-- =============================================================================
-- 3. TABLES (in dependency order)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 airports
-- Reference data: IATA airports seeded below. Not user-owned.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.airports (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  iata_code    text        NOT NULL UNIQUE,
  icao_code    text,
  name         text        NOT NULL,
  city         text        NOT NULL,
  country      text        NOT NULL,
  country_code text        NOT NULL,   -- ISO 3166-1 alpha-2
  latitude     numeric(9,6),
  longitude    numeric(9,6),
  timezone     text,                   -- IANA timezone string
  is_active    boolean     NOT NULL DEFAULT true
);

-- -----------------------------------------------------------------------------
-- 3.2 app_settings
-- Admin-managed option lists: age_range, gender_identity, pronouns, education,
-- ethnicity, interest, block_reason. Managed via Supabase dashboard / SQL.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.app_settings (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  category    text        NOT NULL,  -- e.g. 'age_range', 'interest', 'block_reason'
  value       text        NOT NULL,  -- machine key, e.g. 'non_binary'
  label       text        NOT NULL,  -- display text, e.g. 'Non-binary'
  sort_order  integer     NOT NULL DEFAULT 0,
  is_active   boolean     NOT NULL DEFAULT true,
  deleted_at  timestamptz,
  UNIQUE (category, value)
);

-- -----------------------------------------------------------------------------
-- 3.3 profiles
-- Extends auth.users. id IS the auth user's id (no separate uuid).
-- Auto-created via trigger on auth.users INSERT.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id                   uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  first_name           text,
  last_name            text,
  age_range_id         uuid        REFERENCES public.app_settings(id) ON DELETE SET NULL,
  height_cm            numeric(5,1),                  -- always stored in cm; UI converts for display
  gender_identity_id   uuid        REFERENCES public.app_settings(id) ON DELETE SET NULL,
  pronouns_id          uuid        REFERENCES public.app_settings(id) ON DELETE SET NULL,
  education_id         uuid        REFERENCES public.app_settings(id) ON DELETE SET NULL,
  ethnicity_id         uuid        REFERENCES public.app_settings(id) ON DELETE SET NULL,
  open_to              public.open_to,                -- optional; not used for filtering in v1
  bio                  text,
  profile_complete     boolean     NOT NULL DEFAULT false,
  deleted_at           timestamptz
  -- Note: no created_by — id itself is the user reference
);

-- -----------------------------------------------------------------------------
-- 3.4 profile_photos
-- Up to 3 photos per user. display_order=1 is always the primary photo.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profile_photos (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  profile_id    uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  storage_path  text        NOT NULL,  -- Supabase Storage path: profile-photos/{user_id}/{order}.ext
  display_order integer     NOT NULL DEFAULT 1,  -- 1=primary; max 3 enforced at app level
  deleted_at    timestamptz,
  UNIQUE (profile_id, display_order)
);

-- -----------------------------------------------------------------------------
-- 3.5 profile_interests
-- Junction: profiles × app_settings (category='interest'). Max 5 at app level.
-- Junction pattern: no updated_at / created_by / deleted_at.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profile_interests (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  profile_id  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  setting_id  uuid        NOT NULL REFERENCES public.app_settings(id) ON DELETE CASCADE,
  UNIQUE (profile_id, setting_id)
);

-- -----------------------------------------------------------------------------
-- 3.6 trips
-- A user's travel plan. Overlap matching uses airports + dates + connection_type.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trips (
  id                    uuid                   PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at            timestamptz            NOT NULL DEFAULT now(),
  updated_at            timestamptz            NOT NULL DEFAULT now(),
  created_by            uuid                   NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  departure_airport_id  uuid                   NOT NULL REFERENCES public.airports(id) ON DELETE RESTRICT,
  departure_date        date                   NOT NULL,
  layover_airport_id    uuid                   REFERENCES public.airports(id) ON DELETE RESTRICT,
  layover_date          date,                  -- required when layover_airport_id is set
  arrival_airport_id    uuid                   NOT NULL REFERENCES public.airports(id) ON DELETE RESTRICT,
  arrival_date          date                   NOT NULL,
  connection_type       public.connection_type NOT NULL,
  deleted_at            timestamptz
);

-- -----------------------------------------------------------------------------
-- 3.7 trip_overlaps
-- Computed matches: two trips share an airport on the same date with the same
-- connection_type. Populated by business logic (trigger/RPC) — not directly
-- inserted by the app.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trip_overlaps (
  id                  uuid                   PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at          timestamptz            NOT NULL DEFAULT now(),
  user_a_id           uuid                   NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  user_b_id           uuid                   NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  trip_a_id           uuid                   NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
  trip_b_id           uuid                   NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
  matched_airport_id  uuid                   NOT NULL REFERENCES public.airports(id) ON DELETE RESTRICT,
  overlap_date        date                   NOT NULL,
  connection_type     public.connection_type NOT NULL,
  deleted_at          timestamptz,
  UNIQUE (trip_a_id, trip_b_id, matched_airport_id, overlap_date)
);

-- -----------------------------------------------------------------------------
-- 3.8 connection_requests
-- User A sends a request to User B with an optional brief note.
-- One lifetime request per pair (UNIQUE enforced below).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.connection_requests (
  id            uuid                              PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at    timestamptz                       NOT NULL DEFAULT now(),
  updated_at    timestamptz                       NOT NULL DEFAULT now(),
  created_by    uuid                              NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recipient_id  uuid                              NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  brief_note    text,
  status        public.connection_request_status  NOT NULL DEFAULT 'pending',
  deleted_at    timestamptz,
  UNIQUE (created_by, recipient_id)  -- one lifetime request per ordered pair
);

-- -----------------------------------------------------------------------------
-- 3.9 chats
-- One chat per user pair, created when a connection request is accepted.
-- Functional unique index prevents duplicate pairs regardless of A/B ordering.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chats (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  user_a_id        uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  user_b_id        uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_message_at  timestamptz,  -- denormalized; updated by business logic on new message
  deleted_at       timestamptz
);

-- -----------------------------------------------------------------------------
-- 3.10 messages
-- Messages within a chat. is_read flipped when recipient opens the chat.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.messages (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chat_id     uuid        NOT NULL REFERENCES public.chats(id) ON DELETE CASCADE,
  content     text        NOT NULL,
  is_read     boolean     NOT NULL DEFAULT false,
  deleted_at  timestamptz
);

-- -----------------------------------------------------------------------------
-- 3.11 notifications
-- In-app notifications. 4 types (see notification_type enum).
-- Populated by business logic — not directly inserted by the app.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.notifications (
  id               uuid                      PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at       timestamptz               NOT NULL DEFAULT now(),
  updated_at       timestamptz               NOT NULL DEFAULT now(),
  user_id          uuid                      NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type             public.notification_type  NOT NULL,
  related_user_id  uuid                      REFERENCES public.profiles(id) ON DELETE SET NULL,
  related_trip_id  uuid                      REFERENCES public.trips(id) ON DELETE SET NULL,
  related_chat_id  uuid                      REFERENCES public.chats(id) ON DELETE SET NULL,
  is_read          boolean                   NOT NULL DEFAULT false,
  deleted_at       timestamptz
);

-- -----------------------------------------------------------------------------
-- 3.12 user_blocks
-- When a user blocks another. reason_id from app_settings (category='block_reason').
-- Junction-style: no updated_at / deleted_at. Hard-delete = unblock.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_blocks (
  id              uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  blocked_user_id uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reason_id       uuid        REFERENCES public.app_settings(id) ON DELETE SET NULL,
  UNIQUE (created_by, blocked_user_id)
);


-- =============================================================================
-- 4. VIEWS (active_* — filter soft-deleted rows)
-- FlutterFlow should query these views for all normal operations.
-- =============================================================================

CREATE OR REPLACE VIEW public.active_profiles AS
  SELECT * FROM public.profiles WHERE deleted_at IS NULL;

CREATE OR REPLACE VIEW public.active_trips AS
  SELECT * FROM public.trips WHERE deleted_at IS NULL;

CREATE OR REPLACE VIEW public.active_trip_overlaps AS
  SELECT * FROM public.trip_overlaps WHERE deleted_at IS NULL;

CREATE OR REPLACE VIEW public.active_connection_requests AS
  SELECT * FROM public.connection_requests WHERE deleted_at IS NULL;

CREATE OR REPLACE VIEW public.active_chats AS
  SELECT * FROM public.chats WHERE deleted_at IS NULL;

CREATE OR REPLACE VIEW public.active_messages AS
  SELECT * FROM public.messages WHERE deleted_at IS NULL;

CREATE OR REPLACE VIEW public.active_notifications AS
  SELECT * FROM public.notifications WHERE deleted_at IS NULL;

CREATE OR REPLACE VIEW public.active_app_settings AS
  SELECT * FROM public.app_settings
  WHERE deleted_at IS NULL AND is_active = true;


-- =============================================================================
-- 5. INDEXES
-- =============================================================================

-- airports
CREATE INDEX IF NOT EXISTS idx_airports_iata_code
  ON public.airports(iata_code);

-- app_settings
CREATE INDEX IF NOT EXISTS idx_app_settings_category
  ON public.app_settings(category, sort_order)
  WHERE deleted_at IS NULL AND is_active = true;

-- profiles (FK columns)
CREATE INDEX IF NOT EXISTS idx_profiles_age_range_id
  ON public.profiles(age_range_id);
CREATE INDEX IF NOT EXISTS idx_profiles_gender_identity_id
  ON public.profiles(gender_identity_id);

-- trips (FK + overlap matching columns)
CREATE INDEX IF NOT EXISTS idx_trips_created_by
  ON public.trips(created_by)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_trips_departure_airport_date
  ON public.trips(departure_airport_id, departure_date)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_trips_layover_airport_date
  ON public.trips(layover_airport_id, layover_date)
  WHERE deleted_at IS NULL AND layover_airport_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_trips_arrival_airport_date
  ON public.trips(arrival_airport_id, arrival_date)
  WHERE deleted_at IS NULL;

-- trip_overlaps (primary access patterns)
CREATE INDEX IF NOT EXISTS idx_trip_overlaps_user_a
  ON public.trip_overlaps(user_a_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_trip_overlaps_user_b
  ON public.trip_overlaps(user_b_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_trip_overlaps_trip_a
  ON public.trip_overlaps(trip_a_id);

CREATE INDEX IF NOT EXISTS idx_trip_overlaps_trip_b
  ON public.trip_overlaps(trip_b_id);

-- connection_requests
CREATE INDEX IF NOT EXISTS idx_connection_requests_created_by
  ON public.connection_requests(created_by)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_connection_requests_recipient
  ON public.connection_requests(recipient_id, status)
  WHERE deleted_at IS NULL;

-- chats (functional unique index: 1 chat per user pair regardless of A/B order)
CREATE UNIQUE INDEX IF NOT EXISTS idx_chats_unique_pair
  ON public.chats(
    LEAST(user_a_id::text, user_b_id::text),
    GREATEST(user_a_id::text, user_b_id::text)
  )
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_chats_user_a
  ON public.chats(user_a_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_chats_user_b
  ON public.chats(user_b_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_chats_last_message_at
  ON public.chats(last_message_at DESC)
  WHERE deleted_at IS NULL;

-- messages
CREATE INDEX IF NOT EXISTS idx_messages_chat_id_created
  ON public.messages(chat_id, created_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_messages_unread
  ON public.messages(chat_id)
  WHERE is_read = false AND deleted_at IS NULL;

-- notifications
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
  ON public.notifications(user_id, created_at DESC)
  WHERE is_read = false AND deleted_at IS NULL;

-- user_blocks (lookup in both directions)
CREATE INDEX IF NOT EXISTS idx_user_blocks_created_by
  ON public.user_blocks(created_by);

CREATE INDEX IF NOT EXISTS idx_user_blocks_blocked_user
  ON public.user_blocks(blocked_user_id);


-- =============================================================================
-- 6. FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 handle_updated_at
-- Sets updated_at = now() on every UPDATE. Attached to every table via trigger.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 6.2 handle_new_user
-- Auto-creates a profiles row when a new auth.users row is inserted (signup).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 6.3 handle_profile_anonymization
-- Scrubs PII fields when a profile is soft-deleted (deleted_at: NULL → value).
-- Preserves the row for referential integrity (messages, trip history, etc.).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_profile_anonymization()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
    NEW.first_name          := 'Deleted';
    NEW.last_name           := 'User';
    NEW.bio                 := NULL;
    NEW.height_cm           := NULL;
    NEW.age_range_id        := NULL;
    NEW.gender_identity_id  := NULL;
    NEW.pronouns_id         := NULL;
    NEW.education_id        := NULL;
    NEW.ethnicity_id        := NULL;
    NEW.open_to             := NULL;
    NEW.profile_complete    := false;
  END IF;
  RETURN NEW;
END;
$$;


-- =============================================================================
-- 7. TRIGGERS
-- =============================================================================

-- updated_at triggers (one per table that has updated_at)
CREATE TRIGGER set_updated_at_airports
  BEFORE UPDATE ON public.airports
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_updated_at_app_settings
  BEFORE UPDATE ON public.app_settings
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_updated_at_profiles
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_updated_at_profile_photos
  BEFORE UPDATE ON public.profile_photos
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_updated_at_trips
  BEFORE UPDATE ON public.trips
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_updated_at_connection_requests
  BEFORE UPDATE ON public.connection_requests
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_updated_at_chats
  BEFORE UPDATE ON public.chats
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_updated_at_messages
  BEFORE UPDATE ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_updated_at_notifications
  BEFORE UPDATE ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

-- Profile auto-creation trigger
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Profile anonymization trigger (fires when deleted_at transitions NULL → value)
CREATE TRIGGER anonymize_profile_on_soft_delete
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
  EXECUTE FUNCTION public.handle_profile_anonymization();


-- =============================================================================
-- 8. ROW LEVEL SECURITY
-- =============================================================================

-- Enable RLS on all tables
ALTER TABLE public.airports            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_settings        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profile_photos      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profile_interests   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trips               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trip_overlaps       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connection_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chats               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_blocks         ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- airports — read-only for all authenticated users; no user writes
-- -----------------------------------------------------------------------------
CREATE POLICY airports_select_all
  ON public.airports FOR SELECT
  USING (true);

-- -----------------------------------------------------------------------------
-- app_settings — read-only for all authenticated users; no user writes
-- -----------------------------------------------------------------------------
CREATE POLICY app_settings_select_all
  ON public.app_settings FOR SELECT
  USING (is_active = true AND deleted_at IS NULL);

-- -----------------------------------------------------------------------------
-- profiles
-- All authenticated users can read non-deleted profiles (needed for profile cards).
-- Users can only update their own profile.
-- -----------------------------------------------------------------------------
CREATE POLICY profiles_select_all
  ON public.profiles FOR SELECT
  USING (deleted_at IS NULL);

CREATE POLICY profiles_update_own
  ON public.profiles FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- -----------------------------------------------------------------------------
-- profile_photos
-- Any authenticated user can read active photos (displayed on profile cards).
-- Users manage only their own photos.
-- -----------------------------------------------------------------------------
CREATE POLICY profile_photos_select_all
  ON public.profile_photos FOR SELECT
  USING (deleted_at IS NULL);

CREATE POLICY profile_photos_insert_own
  ON public.profile_photos FOR INSERT
  WITH CHECK (created_by = auth.uid());

CREATE POLICY profile_photos_update_own
  ON public.profile_photos FOR UPDATE
  USING (created_by = auth.uid())
  WITH CHECK (created_by = auth.uid());

CREATE POLICY profile_photos_delete_own
  ON public.profile_photos FOR DELETE
  USING (created_by = auth.uid());

-- -----------------------------------------------------------------------------
-- profile_interests
-- Any authenticated user can read interests (shown on profile views).
-- Users manage only their own interests.
-- -----------------------------------------------------------------------------
CREATE POLICY profile_interests_select_all
  ON public.profile_interests FOR SELECT
  USING (true);

CREATE POLICY profile_interests_insert_own
  ON public.profile_interests FOR INSERT
  WITH CHECK (
    profile_id = auth.uid()
  );

CREATE POLICY profile_interests_delete_own
  ON public.profile_interests FOR DELETE
  USING (profile_id = auth.uid());

-- -----------------------------------------------------------------------------
-- trips
-- Users can always see their own trips.
-- Users can also see trips of others that appear in trip_overlaps where they
-- are a participant (needed to show trip context on profile cards).
-- -----------------------------------------------------------------------------
CREATE POLICY trips_select_own
  ON public.trips FOR SELECT
  USING (created_by = auth.uid() AND deleted_at IS NULL);

CREATE POLICY trips_select_overlapping
  ON public.trips FOR SELECT
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1 FROM public.trip_overlaps o
      WHERE o.deleted_at IS NULL
        AND (
          (o.trip_a_id = trips.id AND o.user_b_id = auth.uid())
          OR
          (o.trip_b_id = trips.id AND o.user_a_id = auth.uid())
        )
    )
  );

CREATE POLICY trips_insert_own
  ON public.trips FOR INSERT
  WITH CHECK (created_by = auth.uid());

CREATE POLICY trips_update_own
  ON public.trips FOR UPDATE
  USING (created_by = auth.uid() AND deleted_at IS NULL)
  WITH CHECK (created_by = auth.uid());

-- -----------------------------------------------------------------------------
-- trip_overlaps
-- Users can see overlaps where they are user_a or user_b.
-- No user inserts/updates — populated by business logic only.
-- -----------------------------------------------------------------------------
CREATE POLICY trip_overlaps_select_participant
  ON public.trip_overlaps FOR SELECT
  USING (
    deleted_at IS NULL
    AND (user_a_id = auth.uid() OR user_b_id = auth.uid())
  );

-- -----------------------------------------------------------------------------
-- connection_requests
-- Users can see requests they sent or received.
-- Users can insert only their own requests (created_by = auth.uid()).
-- Recipient can update status (accept/decline). Sender cannot modify.
-- -----------------------------------------------------------------------------
CREATE POLICY connection_requests_select_participant
  ON public.connection_requests FOR SELECT
  USING (
    deleted_at IS NULL
    AND (created_by = auth.uid() OR recipient_id = auth.uid())
  );

CREATE POLICY connection_requests_insert_own
  ON public.connection_requests FOR INSERT
  WITH CHECK (created_by = auth.uid());

CREATE POLICY connection_requests_update_recipient
  ON public.connection_requests FOR UPDATE
  USING (recipient_id = auth.uid() AND deleted_at IS NULL)
  WITH CHECK (recipient_id = auth.uid());

-- -----------------------------------------------------------------------------
-- chats
-- Users can see chats where they are user_a or user_b.
-- No user inserts — created by business logic when request is accepted.
-- -----------------------------------------------------------------------------
CREATE POLICY chats_select_participant
  ON public.chats FOR SELECT
  USING (
    deleted_at IS NULL
    AND (user_a_id = auth.uid() OR user_b_id = auth.uid())
  );

-- -----------------------------------------------------------------------------
-- messages
-- Users can read messages in chats they belong to.
-- Users can insert messages into their own chats.
-- Users can update their own messages (e.g., mark as read is handled by business logic).
-- -----------------------------------------------------------------------------
CREATE POLICY messages_select_participant
  ON public.messages FOR SELECT
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = messages.chat_id
        AND c.deleted_at IS NULL
        AND (c.user_a_id = auth.uid() OR c.user_b_id = auth.uid())
    )
  );

CREATE POLICY messages_insert_own
  ON public.messages FOR INSERT
  WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_id
        AND c.deleted_at IS NULL
        AND (c.user_a_id = auth.uid() OR c.user_b_id = auth.uid())
    )
  );

CREATE POLICY messages_update_own
  ON public.messages FOR UPDATE
  USING (created_by = auth.uid() AND deleted_at IS NULL)
  WITH CHECK (created_by = auth.uid());

-- -----------------------------------------------------------------------------
-- notifications
-- Users can only see and update their own notifications.
-- No user inserts — created by business logic.
-- -----------------------------------------------------------------------------
CREATE POLICY notifications_select_own
  ON public.notifications FOR SELECT
  USING (user_id = auth.uid() AND deleted_at IS NULL);

CREATE POLICY notifications_update_own
  ON public.notifications FOR UPDATE
  USING (user_id = auth.uid() AND deleted_at IS NULL)
  WITH CHECK (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- user_blocks
-- Users can see, create, and delete their own blocks.
-- -----------------------------------------------------------------------------
CREATE POLICY user_blocks_select_own
  ON public.user_blocks FOR SELECT
  USING (created_by = auth.uid());

CREATE POLICY user_blocks_insert_own
  ON public.user_blocks FOR INSERT
  WITH CHECK (created_by = auth.uid());

CREATE POLICY user_blocks_delete_own
  ON public.user_blocks FOR DELETE
  USING (created_by = auth.uid());


-- =============================================================================
-- 9. SEED DATA
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 9.1 app_settings seed
-- -----------------------------------------------------------------------------
INSERT INTO public.app_settings (category, value, label, sort_order) VALUES
  -- age_range
  ('age_range', '18_24',  '18–24',  1),
  ('age_range', '25_30',  '25–30',  2),
  ('age_range', '31_35',  '31–35',  3),
  ('age_range', '36_40',  '36–40',  4),
  ('age_range', '41_50',  '41–50',  5),
  ('age_range', '51_plus', '51+',   6),

  -- gender_identity
  ('gender_identity', 'man',            'Man',             1),
  ('gender_identity', 'woman',          'Woman',           2),
  ('gender_identity', 'non_binary',     'Non-binary',      3),
  ('gender_identity', 'genderfluid',    'Genderfluid',     4),
  ('gender_identity', 'agender',        'Agender',         5),
  ('gender_identity', 'other',          'Other',           6),
  ('gender_identity', 'prefer_not_say', 'Prefer not to say', 7),

  -- pronouns
  ('pronouns', 'he_him',        'He/Him',          1),
  ('pronouns', 'she_her',       'She/Her',         2),
  ('pronouns', 'they_them',     'They/Them',       3),
  ('pronouns', 'he_they',       'He/They',         4),
  ('pronouns', 'she_they',      'She/They',        5),
  ('pronouns', 'any',           'Any pronouns',    6),
  ('pronouns', 'prefer_not_say','Prefer not to say', 7),

  -- education
  ('education', 'high_school',    'High School',        1),
  ('education', 'some_college',   'Some College',       2),
  ('education', 'associates',     'Associate''s Degree', 3),
  ('education', 'bachelors',      'Bachelor''s Degree', 4),
  ('education', 'masters',        'Master''s Degree',   5),
  ('education', 'doctorate',      'Doctorate',          6),
  ('education', 'trade_school',   'Trade School',       7),
  ('education', 'prefer_not_say', 'Prefer not to say',  8),

  -- ethnicity
  ('ethnicity', 'asian',              'Asian',                    1),
  ('ethnicity', 'black',              'Black / African American', 2),
  ('ethnicity', 'hispanic',           'Hispanic / Latino',        3),
  ('ethnicity', 'middle_eastern',     'Middle Eastern',           4),
  ('ethnicity', 'native_american',    'Native American',          5),
  ('ethnicity', 'pacific_islander',   'Pacific Islander',         6),
  ('ethnicity', 'white',              'White / Caucasian',        7),
  ('ethnicity', 'mixed',              'Mixed',                    8),
  ('ethnicity', 'prefer_not_say',     'Prefer not to say',        9),
  ('ethnicity', 'other',              'Other',                   10),

  -- interest (travel style)
  ('interest', 'adventure',    'Adventure Travel',    1),
  ('interest', 'beach',        'Beach Lover',         2),
  ('interest', 'city',         'City Explorer',       3),
  ('interest', 'food',         'Food & Dining',       4),
  ('interest', 'culture',      'Culture & History',   5),
  ('interest', 'photography',  'Photography',         6),
  ('interest', 'nature',       'Nature & Hiking',     7),
  ('interest', 'luxury',       'Luxury Travel',       8),
  ('interest', 'budget',       'Budget Travel',       9),
  ('interest', 'backpacking',  'Backpacking',        10),
  ('interest', 'road_trips',   'Road Trips',         11),
  ('interest', 'cruises',      'Cruises',            12),
  ('interest', 'business',     'Business Travel',    13),
  ('interest', 'solo',         'Solo Travel',        14),
  ('interest', 'wellness',     'Wellness & Spa',     15),
  ('interest', 'festivals',    'Festivals & Events', 16),
  ('interest', 'sports',       'Sports & Fitness',   17),
  ('interest', 'nightlife',    'Nightlife',          18),
  ('interest', 'eco',          'Eco-Tourism',        19),

  -- block_reason
  ('block_reason', 'inappropriate', 'Inappropriate behavior', 1),
  ('block_reason', 'spam',          'Spam',                   2),
  ('block_reason', 'harassment',    'Harassment',             3),
  ('block_reason', 'fake_profile',  'Fake profile',           4),
  ('block_reason', 'other',         'Other',                  5)

ON CONFLICT (category, value) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 9.2 airports seed
-- Major international airports. Full dataset can be imported from openflights.org.
-- -----------------------------------------------------------------------------
INSERT INTO public.airports (iata_code, icao_code, name, city, country, country_code, latitude, longitude, timezone) VALUES
  -- United States
  ('ATL', 'KATL', 'Hartsfield-Jackson Atlanta International',        'Atlanta',          'United States', 'US',  33.636700, -84.428101, 'America/New_York'),
  ('LAX', 'KLAX', 'Los Angeles International',                       'Los Angeles',      'United States', 'US',  33.942501, -118.407997,'America/Los_Angeles'),
  ('ORD', 'KORD', 'O''Hare International',                           'Chicago',          'United States', 'US',  41.978600, -87.904800, 'America/Chicago'),
  ('DFW', 'KDFW', 'Dallas/Fort Worth International',                 'Dallas',           'United States', 'US',  32.896801, -97.038002, 'America/Chicago'),
  ('DEN', 'KDEN', 'Denver International',                            'Denver',           'United States', 'US',  39.861698, -104.672997,'America/Denver'),
  ('JFK', 'KJFK', 'John F. Kennedy International',                   'New York',         'United States', 'US',  40.639801, -73.778900, 'America/New_York'),
  ('SFO', 'KSFO', 'San Francisco International',                     'San Francisco',    'United States', 'US',  37.618999, -122.375000,'America/Los_Angeles'),
  ('SEA', 'KSEA', 'Seattle-Tacoma International',                    'Seattle',          'United States', 'US',  47.449001, -122.308998,'America/Los_Angeles'),
  ('LAS', 'KLAS', 'Harry Reid International',                        'Las Vegas',        'United States', 'US',  36.080799, -115.152000,'America/Los_Angeles'),
  ('MCO', 'KMCO', 'Orlando International',                           'Orlando',          'United States', 'US',  28.429399, -81.309097, 'America/New_York'),
  ('EWR', 'KEWR', 'Newark Liberty International',                    'Newark',           'United States', 'US',  40.692501, -74.168701, 'America/New_York'),
  ('CLT', 'KCLT', 'Charlotte Douglas International',                 'Charlotte',        'United States', 'US',  35.213799, -80.943100, 'America/New_York'),
  ('PHX', 'KPHX', 'Phoenix Sky Harbor International',                'Phoenix',          'United States', 'US',  33.437901, -112.007004,'America/Phoenix'),
  ('IAH', 'KIAH', 'George Bush Intercontinental',                    'Houston',          'United States', 'US',  29.984400, -95.341400, 'America/Chicago'),
  ('MIA', 'KMIA', 'Miami International',                             'Miami',            'United States', 'US',  25.795900, -80.287201, 'America/New_York'),
  ('BOS', 'KBOS', 'Logan International',                             'Boston',           'United States', 'US',  42.364300, -71.005203, 'America/New_York'),
  ('MSP', 'KMSP', 'Minneapolis–Saint Paul International',            'Minneapolis',      'United States', 'US',  44.882000, -93.221802, 'America/Chicago'),
  ('DTW', 'KDTW', 'Detroit Metropolitan Wayne County',               'Detroit',          'United States', 'US',  42.212399, -83.353401, 'America/Detroit'),
  ('FLL', 'KFLL', 'Fort Lauderdale-Hollywood International',         'Fort Lauderdale',  'United States', 'US',  26.072599, -80.152702, 'America/New_York'),
  ('PHL', 'KPHL', 'Philadelphia International',                      'Philadelphia',     'United States', 'US',  39.871899, -75.241096, 'America/New_York'),
  ('LGA', 'KLGA', 'LaGuardia',                                       'New York',         'United States', 'US',  40.777199, -73.872597, 'America/New_York'),
  ('BWI', 'KBWI', 'Baltimore/Washington International',              'Baltimore',        'United States', 'US',  39.175400, -76.668297, 'America/New_York'),
  ('SLC', 'KSLC', 'Salt Lake City International',                    'Salt Lake City',   'United States', 'US',  40.788399, -111.977997,'America/Denver'),
  ('SAN', 'KSAN', 'San Diego International',                         'San Diego',        'United States', 'US',  32.733601, -117.190002,'America/Los_Angeles'),
  ('IAD', 'KIAD', 'Washington Dulles International',                 'Washington D.C.',  'United States', 'US',  38.944500, -77.455803, 'America/New_York'),
  ('TPA', 'KTPA', 'Tampa International',                             'Tampa',            'United States', 'US',  27.975500, -82.533203, 'America/New_York'),
  ('PDX', 'KPDX', 'Portland International',                          'Portland',         'United States', 'US',  45.588699, -122.598000,'America/Los_Angeles'),
  ('AUS', 'KAUS', 'Austin-Bergstrom International',                  'Austin',           'United States', 'US',  30.197201, -97.666000, 'America/Chicago'),
  ('BNA', 'KBNA', 'Nashville International',                         'Nashville',        'United States', 'US',  36.124500, -86.678200, 'America/Chicago'),
  ('MCI', 'KMCI', 'Kansas City International',                       'Kansas City',      'United States', 'US',  39.297901, -94.713898, 'America/Chicago'),
  ('RDU', 'KRDU', 'Raleigh-Durham International',                    'Raleigh',          'United States', 'US',  35.877602, -78.787498, 'America/New_York'),
  ('SMF', 'KSMF', 'Sacramento International',                        'Sacramento',       'United States', 'US',  38.695400, -121.590996,'America/Los_Angeles'),
  ('MDW', 'KMDW', 'Chicago Midway International',                    'Chicago',          'United States', 'US',  41.785999, -87.752403, 'America/Chicago'),
  ('DAL', 'KDAL', 'Dallas Love Field',                               'Dallas',           'United States', 'US',  32.847099, -96.851799, 'America/Chicago'),
  ('HOU', 'KHOU', 'William P. Hobby',                                'Houston',          'United States', 'US',  29.645399, -95.278900, 'America/Chicago'),
  ('DCA', 'KDCA', 'Ronald Reagan Washington National',               'Washington D.C.',  'United States', 'US',  38.852100, -77.037697, 'America/New_York'),
  ('SJC', 'KSJC', 'Norman Y. Mineta San Jose International',         'San Jose',         'United States', 'US',  37.362598, -121.929001,'America/Los_Angeles'),
  ('OAK', 'KOAK', 'Oakland International',                           'Oakland',          'United States', 'US',  37.721298, -122.220993,'America/Los_Angeles'),
  ('STL', 'KSTL', 'St. Louis Lambert International',                 'St. Louis',        'United States', 'US',  38.748697, -90.370003, 'America/Chicago'),
  ('MSY', 'KMSY', 'Louis Armstrong New Orleans International',       'New Orleans',      'United States', 'US',  29.993401, -90.258003, 'America/Chicago'),
  ('PIT', 'KPIT', 'Pittsburgh International',                        'Pittsburgh',       'United States', 'US',  40.491501, -80.232902, 'America/New_York'),
  ('CLE', 'KCLE', 'Cleveland Hopkins International',                 'Cleveland',        'United States', 'US',  41.411301, -81.849800, 'America/New_York'),
  ('IND', 'KIND', 'Indianapolis International',                      'Indianapolis',     'United States', 'US',  39.717300, -86.294403, 'America/Indiana/Indianapolis'),
  ('CMH', 'KCMH', 'John Glenn Columbus International',               'Columbus',         'United States', 'US',  39.998001, -82.891899, 'America/New_York'),
  ('ABQ', 'KABQ', 'Albuquerque International Sunport',               'Albuquerque',      'United States', 'US',  35.040199, -106.609001,'America/Denver'),
  ('HNL', 'PHNL', 'Daniel K. Inouye International',                  'Honolulu',         'United States', 'US',  21.318699, -157.922005,'Pacific/Honolulu'),
  ('ANC', 'PANC', 'Ted Stevens Anchorage International',             'Anchorage',        'United States', 'US',  61.174400, -149.996002,'America/Anchorage'),

  -- Canada
  ('YYZ', 'CYYZ', 'Toronto Pearson International',                   'Toronto',          'Canada',        'CA',  43.677200, -79.630600, 'America/Toronto'),
  ('YVR', 'CYVR', 'Vancouver International',                         'Vancouver',        'Canada',        'CA',  49.193901, -123.184000,'America/Vancouver'),
  ('YUL', 'CYUL', 'Montreal-Trudeau International',                  'Montreal',         'Canada',        'CA',  45.470501, -73.740700, 'America/Toronto'),
  ('YYC', 'CYYC', 'Calgary International',                           'Calgary',          'Canada',        'CA',  51.113899, -114.020000,'America/Edmonton'),
  ('YEG', 'CYEG', 'Edmonton International',                          'Edmonton',         'Canada',        'CA',  53.309700, -113.580002,'America/Edmonton'),

  -- United Kingdom
  ('LHR', 'EGLL', 'London Heathrow',                                 'London',           'United Kingdom','GB',  51.477500, -0.461389,  'Europe/London'),
  ('LGW', 'EGKK', 'London Gatwick',                                  'London',           'United Kingdom','GB',  51.148102, -0.190278,  'Europe/London'),
  ('MAN', 'EGCC', 'Manchester Airport',                              'Manchester',       'United Kingdom','GB',  53.353699, -2.274950,  'Europe/London'),
  ('EDI', 'EGPH', 'Edinburgh Airport',                               'Edinburgh',        'United Kingdom','GB',  55.950001, -3.372500,  'Europe/London'),

  -- Europe
  ('CDG', 'LFPG', 'Charles de Gaulle',                               'Paris',            'France',        'FR',  49.012798, 2.550000,   'Europe/Paris'),
  ('ORY', 'LFPO', 'Paris Orly',                                      'Paris',            'France',        'FR',  48.723400, 2.379440,   'Europe/Paris'),
  ('AMS', 'EHAM', 'Amsterdam Schiphol',                              'Amsterdam',        'Netherlands',   'NL',  52.308601, 4.763890,   'Europe/Amsterdam'),
  ('FRA', 'EDDF', 'Frankfurt Airport',                               'Frankfurt',        'Germany',       'DE',  50.033333, 8.570556,   'Europe/Berlin'),
  ('MUC', 'EDDM', 'Munich Airport',                                  'Munich',           'Germany',       'DE',  48.353802, 11.786100,  'Europe/Berlin'),
  ('BER', 'EDDB', 'Berlin Brandenburg',                              'Berlin',           'Germany',       'DE',  52.366699, 13.503200,  'Europe/Berlin'),
  ('MAD', 'LEMD', 'Adolfo Suárez Madrid–Barajas',                    'Madrid',           'Spain',         'ES',  40.471926, -3.560264,  'Europe/Madrid'),
  ('BCN', 'LEBL', 'Barcelona–El Prat',                               'Barcelona',        'Spain',         'ES',  41.296900, 2.078460,   'Europe/Madrid'),
  ('FCO', 'LIRF', 'Leonardo da Vinci–Fiumicino',                     'Rome',             'Italy',         'IT',  41.804501, 12.250900,  'Europe/Rome'),
  ('MXP', 'LIMC', 'Milan Malpensa',                                  'Milan',            'Italy',         'IT',  45.630600, 8.728110,   'Europe/Rome'),
  ('LIS', 'LPPT', 'Humberto Delgado (Lisbon)',                       'Lisbon',           'Portugal',      'PT',  38.781300, -9.135920,  'Europe/Lisbon'),
  ('ATH', 'LGAV', 'Athens International (Eleftherios Venizelos)',    'Athens',           'Greece',        'GR',  37.936401, 23.944500,  'Europe/Athens'),
  ('VIE', 'LOWW', 'Vienna International',                            'Vienna',           'Austria',       'AT',  48.110298, 16.569700,  'Europe/Vienna'),
  ('ZRH', 'LSZH', 'Zurich Airport',                                  'Zurich',           'Switzerland',   'CH',  47.464699, 8.549170,   'Europe/Zurich'),
  ('GVA', 'LSGG', 'Geneva Airport',                                  'Geneva',           'Switzerland',   'CH',  46.238098, 6.108950,   'Europe/Zurich'),
  ('BRU', 'EBBR', 'Brussels Airport',                                'Brussels',         'Belgium',       'BE',  50.901402, 4.484440,   'Europe/Brussels'),
  ('CPH', 'EKCH', 'Copenhagen Airport',                              'Copenhagen',       'Denmark',       'DK',  55.617901, 12.656000,  'Europe/Copenhagen'),
  ('ARN', 'ESSA', 'Stockholm Arlanda',                               'Stockholm',        'Sweden',        'SE',  59.651901, 17.918600,  'Europe/Stockholm'),
  ('OSL', 'ENGM', 'Oslo Gardermoen',                                 'Oslo',             'Norway',        'NO',  60.193901, 11.100400,  'Europe/Oslo'),
  ('HEL', 'EFHK', 'Helsinki-Vantaa',                                 'Helsinki',         'Finland',       'FI',  60.317200, 24.963301,  'Europe/Helsinki'),
  ('DUB', 'EIDW', 'Dublin Airport',                                  'Dublin',           'Ireland',       'IE',  53.421299, -6.270070,  'Europe/Dublin'),
  ('IST', 'LTFM', 'Istanbul Airport',                                'Istanbul',         'Turkey',        'TR',  41.275278, 28.751944,  'Europe/Istanbul'),
  ('WAW', 'EPWA', 'Warsaw Chopin',                                   'Warsaw',           'Poland',        'PL',  52.165699, 20.967100,  'Europe/Warsaw'),
  ('PRG', 'LKPR', 'Václav Havel Airport Prague',                     'Prague',           'Czech Republic','CZ',  50.100800, 14.260600,  'Europe/Prague'),
  ('BUD', 'LHBP', 'Budapest Ferenc Liszt International',             'Budapest',         'Hungary',       'HU',  47.436901, 19.261000,  'Europe/Budapest'),
  ('AMS', 'EHAM', 'Amsterdam Schiphol',                              'Amsterdam',        'Netherlands',   'NL',  52.308601, 4.763890,   'Europe/Amsterdam'),

  -- Middle East & Africa
  ('DXB', 'OMDB', 'Dubai International',                             'Dubai',            'UAE',           'AE',  25.252800, 55.364399,  'Asia/Dubai'),
  ('AUH', 'OMAA', 'Abu Dhabi International',                         'Abu Dhabi',        'UAE',           'AE',  24.432999, 54.651100,  'Asia/Dubai'),
  ('DOH', 'OTHH', 'Hamad International',                             'Doha',             'Qatar',         'QA',  25.273056, 51.608056,  'Asia/Qatar'),
  ('RUH', 'OERK', 'King Khalid International',                       'Riyadh',           'Saudi Arabia',  'SA',  24.957500, 46.698799,  'Asia/Riyadh'),
  ('JED', 'OEJN', 'King Abdulaziz International',                    'Jeddah',           'Saudi Arabia',  'SA',  21.679600, 39.156502,  'Asia/Riyadh'),
  ('CAI', 'HECA', 'Cairo International',                             'Cairo',            'Egypt',         'EG',  30.121901, 31.405600,  'Africa/Cairo'),
  ('JNB', 'FAOR', 'O.R. Tambo International',                        'Johannesburg',     'South Africa',  'ZA', -26.133600, 28.242000,  'Africa/Johannesburg'),
  ('CPT', 'FACT', 'Cape Town International',                         'Cape Town',        'South Africa',  'ZA', -33.964802, 18.601700,  'Africa/Johannesburg'),
  ('NBO', 'HKJK', 'Jomo Kenyatta International',                     'Nairobi',          'Kenya',         'KE',  -1.319240, 36.927502,  'Africa/Nairobi'),
  ('LOS', 'DNMM', 'Murtala Muhammed International',                  'Lagos',            'Nigeria',       'NG',   6.577370, 3.321160,   'Africa/Lagos'),
  ('CMN', 'GMMN', 'Mohammed V International',                        'Casablanca',       'Morocco',       'MA',  33.367500, -7.589970,  'Africa/Casablanca'),

  -- Asia-Pacific
  ('HKG', 'VHHH', 'Hong Kong International',                        'Hong Kong',        'Hong Kong',     'HK',  22.308901, 113.915001, 'Asia/Hong_Kong'),
  ('NRT', 'RJAA', 'Narita International',                            'Tokyo',            'Japan',         'JP',  35.764702, 140.385994, 'Asia/Tokyo'),
  ('HND', 'RJTT', 'Tokyo Haneda',                                    'Tokyo',            'Japan',         'JP',  35.552299, 139.779999, 'Asia/Tokyo'),
  ('KIX', 'RJBB', 'Kansai International',                            'Osaka',            'Japan',         'JP',  34.427299, 135.244003, 'Asia/Tokyo'),
  ('ICN', 'RKSI', 'Incheon International',                           'Seoul',            'South Korea',   'KR',  37.469101, 126.451004, 'Asia/Seoul'),
  ('GMP', 'RKSS', 'Gimpo International',                             'Seoul',            'South Korea',   'KR',  37.558399, 126.791000, 'Asia/Seoul'),
  ('PEK', 'ZBAA', 'Beijing Capital International',                   'Beijing',          'China',         'CN',  40.080101, 116.584999, 'Asia/Shanghai'),
  ('PKX', 'ZBAD', 'Beijing Daxing International',                    'Beijing',          'China',         'CN',  39.509300, 116.410004, 'Asia/Shanghai'),
  ('PVG', 'ZSPD', 'Shanghai Pudong International',                   'Shanghai',         'China',         'CN',  31.143400, 121.805000, 'Asia/Shanghai'),
  ('SHA', 'ZSSS', 'Shanghai Hongqiao International',                 'Shanghai',         'China',         'CN',  31.197901, 121.336000, 'Asia/Shanghai'),
  ('CAN', 'ZGGG', 'Guangzhou Baiyun International',                  'Guangzhou',        'China',         'CN',  23.392401, 113.299004, 'Asia/Shanghai'),
  ('CTU', 'ZUUU', 'Chengdu Tianfu International',                    'Chengdu',          'China',         'CN',  30.312798, 104.444000, 'Asia/Shanghai'),
  ('SIN', 'WSSS', 'Singapore Changi',                                'Singapore',        'Singapore',     'SG',   1.350190, 103.994003, 'Asia/Singapore'),
  ('BKK', 'VTBS', 'Suvarnabhumi',                                    'Bangkok',          'Thailand',      'TH',  13.681100, 100.747002, 'Asia/Bangkok'),
  ('DMK', 'VTBD', 'Don Mueang International',                        'Bangkok',          'Thailand',      'TH',  13.912599, 100.607002, 'Asia/Bangkok'),
  ('KUL', 'WMKK', 'Kuala Lumpur International',                      'Kuala Lumpur',     'Malaysia',      'MY',   2.745600, 101.709999, 'Asia/Kuala_Lumpur'),
  ('CGK', 'WIII', 'Soekarno-Hatta International',                    'Jakarta',          'Indonesia',     'ID',  -6.125670, 106.655998, 'Asia/Jakarta'),
  ('MNL', 'RPLL', 'Ninoy Aquino International',                      'Manila',           'Philippines',   'PH',  14.508600, 121.019997, 'Asia/Manila'),
  ('DEL', 'VIDP', 'Indira Gandhi International',                     'Delhi',            'India',         'IN',  28.556600, 77.100998,  'Asia/Kolkata'),
  ('BOM', 'VABB', 'Chhatrapati Shivaji Maharaj International',       'Mumbai',           'India',         'IN',  19.088699, 72.867897,  'Asia/Kolkata'),
  ('BLR', 'VOBL', 'Kempegowda International',                        'Bengaluru',        'India',         'IN',  13.198900, 77.706299,  'Asia/Kolkata'),
  ('MAA', 'VOMM', 'Chennai International',                           'Chennai',          'India',         'IN',  12.990005, 80.169296,  'Asia/Kolkata'),
  ('HYD', 'VOHS', 'Rajiv Gandhi International',                      'Hyderabad',        'India',         'IN',  17.231318, 78.429855,  'Asia/Kolkata'),
  ('COK', 'VOCI', 'Cochin International',                            'Kochi',            'India',         'IN',  10.152000, 76.401901,  'Asia/Kolkata'),
  ('SYD', 'YSSY', 'Sydney Kingsford Smith',                          'Sydney',           'Australia',     'AU', -33.946098, 151.177002, 'Australia/Sydney'),
  ('MEL', 'YMML', 'Melbourne Airport',                               'Melbourne',        'Australia',     'AU', -37.673302, 144.843002, 'Australia/Melbourne'),
  ('BNE', 'YBBN', 'Brisbane Airport',                                'Brisbane',         'Australia',     'AU', -27.384199, 153.117004, 'Australia/Brisbane'),
  ('PER', 'YPPH', 'Perth Airport',                                   'Perth',            'Australia',     'AU', -31.940201, 115.967003, 'Australia/Perth'),
  ('AKL', 'NZAA', 'Auckland Airport',                                'Auckland',         'New Zealand',   'NZ', -37.008099, 174.792007, 'Pacific/Auckland'),

  -- Latin America
  ('GRU', 'SBGR', 'São Paulo–Guarulhos International',               'São Paulo',        'Brazil',        'BR', -23.432501, -46.469398, 'America/Sao_Paulo'),
  ('GIG', 'SBGL', 'Rio de Janeiro–Galeão International',             'Rio de Janeiro',   'Brazil',        'BR', -22.809999, -43.250599, 'America/Sao_Paulo'),
  ('BSB', 'SBBR', 'Brasília International',                          'Brasília',         'Brazil',        'BR', -15.869200, -47.920898, 'America/Sao_Paulo'),
  ('EZE', 'SAEZ', 'Ministro Pistarini International',                'Buenos Aires',     'Argentina',     'AR', -34.822201, -58.535801, 'America/Argentina/Buenos_Aires'),
  ('SCL', 'SCEL', 'Comodoro Arturo Benitez International',           'Santiago',         'Chile',         'CL', -33.392899, -70.785797, 'America/Santiago'),
  ('LIM', 'SPJC', 'Jorge Chávez International',                      'Lima',             'Peru',          'PE', -12.021900, -77.114304, 'America/Lima'),
  ('BOG', 'SKBO', 'El Dorado International',                         'Bogotá',           'Colombia',      'CO',   4.701600, -74.146904, 'America/Bogota'),
  ('MEX', 'MMMX', 'Benito Juárez International',                     'Mexico City',      'Mexico',        'MX',  19.436298, -99.072098, 'America/Mexico_City'),
  ('CUN', 'MMUN', 'Cancún International',                            'Cancún',           'Mexico',        'MX',  21.036501, -86.877098, 'America/Cancun'),
  ('PTY', 'MPTO', 'Tocumen International',                           'Panama City',      'Panama',        'PA',   9.071360, -79.383499, 'America/Panama')

ON CONFLICT (iata_code) DO NOTHING;

COMMIT;
