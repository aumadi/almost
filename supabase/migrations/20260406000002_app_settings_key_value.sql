-- =============================================================================
-- Restructure app_settings to a simple key → jsonb value table.
-- Each category (ethnicity, age_range, etc.) has ONE row; the JSON array
-- holds all the options for that category.
--
-- Also migrates the consumer columns away from UUID FKs to plain text keys.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Drop FK constraints on consumer tables
-- -----------------------------------------------------------------------------
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_age_range_id_fkey,
  DROP CONSTRAINT IF EXISTS profiles_gender_identity_id_fkey,
  DROP CONSTRAINT IF EXISTS profiles_pronouns_id_fkey,
  DROP CONSTRAINT IF EXISTS profiles_education_id_fkey,
  DROP CONSTRAINT IF EXISTS profiles_ethnicity_id_fkey;

ALTER TABLE public.profile_interests
  DROP CONSTRAINT IF EXISTS profile_interests_setting_id_fkey;

ALTER TABLE public.user_blocks
  DROP CONSTRAINT IF EXISTS user_blocks_reason_id_fkey;

-- -----------------------------------------------------------------------------
-- 2. Replace UUID FK columns with plain text key columns in profiles
-- -----------------------------------------------------------------------------
ALTER TABLE public.profiles
  DROP COLUMN IF EXISTS age_range_id,
  DROP COLUMN IF EXISTS gender_identity_id,
  DROP COLUMN IF EXISTS pronouns_id,
  DROP COLUMN IF EXISTS education_id,
  DROP COLUMN IF EXISTS ethnicity_id;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS age_range       text,
  ADD COLUMN IF NOT EXISTS gender_identity text,
  ADD COLUMN IF NOT EXISTS pronouns        text,
  ADD COLUMN IF NOT EXISTS education       text,
  ADD COLUMN IF NOT EXISTS ethnicity       text;

-- -----------------------------------------------------------------------------
-- 3. Replace setting_id (uuid) with interest_key (text) in profile_interests
-- -----------------------------------------------------------------------------
ALTER TABLE public.profile_interests
  DROP COLUMN IF EXISTS setting_id;

ALTER TABLE public.profile_interests
  ADD COLUMN IF NOT EXISTS interest_key text NOT NULL DEFAULT '';

-- Restore uniqueness on the new column
ALTER TABLE public.profile_interests
  DROP CONSTRAINT IF EXISTS profile_interests_profile_id_setting_id_key;

ALTER TABLE public.profile_interests
  ADD CONSTRAINT profile_interests_profile_id_interest_key_key
    UNIQUE (profile_id, interest_key);

-- -----------------------------------------------------------------------------
-- 4. Replace reason_id (uuid) with reason_key (text) in user_blocks
-- -----------------------------------------------------------------------------
ALTER TABLE public.user_blocks
  DROP COLUMN IF EXISTS reason_id;

ALTER TABLE public.user_blocks
  ADD COLUMN IF NOT EXISTS reason_key text;

-- -----------------------------------------------------------------------------
-- 5. Drop old app_settings table (index, trigger, policy first)
-- -----------------------------------------------------------------------------
DROP TRIGGER  IF EXISTS set_updated_at_app_settings ON public.app_settings;
DROP INDEX    IF EXISTS idx_app_settings_category;
DROP POLICY   IF EXISTS app_settings_select_all ON public.app_settings;
DROP TABLE    IF EXISTS public.app_settings;

-- -----------------------------------------------------------------------------
-- 6. Create new key-value app_settings table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.app_settings (
  key        text        PRIMARY KEY,          -- e.g. 'ethnicity', 'age_range'
  value      jsonb       NOT NULL,             -- array of { key, label, sort_order }
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- RLS
ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY app_settings_select_all
  ON public.app_settings FOR SELECT
  TO authenticated
  USING (true);

-- -----------------------------------------------------------------------------
-- 7. Seed — one row per category, value is a JSON array of options
-- -----------------------------------------------------------------------------
INSERT INTO public.app_settings (key, value) VALUES

  ('age_range', '[
    {"key": "18_24",   "label": "18–24",  "sort_order": 1},
    {"key": "25_30",   "label": "25–30",  "sort_order": 2},
    {"key": "31_35",   "label": "31–35",  "sort_order": 3},
    {"key": "36_40",   "label": "36–40",  "sort_order": 4},
    {"key": "41_50",   "label": "41–50",  "sort_order": 5},
    {"key": "51_plus", "label": "51+",    "sort_order": 6}
  ]'::jsonb),

  ('gender_identity', '[
    {"key": "man",            "label": "Man",                "sort_order": 1},
    {"key": "woman",          "label": "Woman",              "sort_order": 2},
    {"key": "non_binary",     "label": "Non-binary",         "sort_order": 3},
    {"key": "genderfluid",    "label": "Genderfluid",        "sort_order": 4},
    {"key": "agender",        "label": "Agender",            "sort_order": 5},
    {"key": "other",          "label": "Other",              "sort_order": 6},
    {"key": "prefer_not_say", "label": "Prefer not to say", "sort_order": 7}
  ]'::jsonb),

  ('pronouns', '[
    {"key": "he_him",        "label": "He/Him",             "sort_order": 1},
    {"key": "she_her",       "label": "She/Her",            "sort_order": 2},
    {"key": "they_them",     "label": "They/Them",          "sort_order": 3},
    {"key": "he_they",       "label": "He/They",            "sort_order": 4},
    {"key": "she_they",      "label": "She/They",           "sort_order": 5},
    {"key": "any",           "label": "Any pronouns",       "sort_order": 6},
    {"key": "prefer_not_say","label": "Prefer not to say",  "sort_order": 7}
  ]'::jsonb),

  ('education', '[
    {"key": "high_school",    "label": "High School",           "sort_order": 1},
    {"key": "some_college",   "label": "Some College",          "sort_order": 2},
    {"key": "associates",     "label": "Associate''s Degree",   "sort_order": 3},
    {"key": "bachelors",      "label": "Bachelor''s Degree",    "sort_order": 4},
    {"key": "masters",        "label": "Master''s Degree",      "sort_order": 5},
    {"key": "doctorate",      "label": "Doctorate",             "sort_order": 6},
    {"key": "trade_school",   "label": "Trade School",          "sort_order": 7},
    {"key": "prefer_not_say", "label": "Prefer not to say",     "sort_order": 8}
  ]'::jsonb),

  ('ethnicity', '[
    {"key": "asian",           "label": "Asian",                    "sort_order": 1},
    {"key": "black",           "label": "Black / African American", "sort_order": 2},
    {"key": "hispanic",        "label": "Hispanic / Latino",        "sort_order": 3},
    {"key": "middle_eastern",  "label": "Middle Eastern",           "sort_order": 4},
    {"key": "native_american", "label": "Native American",          "sort_order": 5},
    {"key": "pacific_islander","label": "Pacific Islander",         "sort_order": 6},
    {"key": "white",           "label": "White / Caucasian",        "sort_order": 7},
    {"key": "mixed",           "label": "Mixed",                    "sort_order": 8},
    {"key": "prefer_not_say",  "label": "Prefer not to say",        "sort_order": 9},
    {"key": "other",           "label": "Other",                   "sort_order": 10}
  ]'::jsonb),

  ('interest', '[
    {"key": "adventure",   "label": "Adventure Travel",    "sort_order": 1},
    {"key": "beach",       "label": "Beach Lover",         "sort_order": 2},
    {"key": "city",        "label": "City Explorer",       "sort_order": 3},
    {"key": "food",        "label": "Food & Dining",       "sort_order": 4},
    {"key": "culture",     "label": "Culture & History",   "sort_order": 5},
    {"key": "photography", "label": "Photography",         "sort_order": 6},
    {"key": "nature",      "label": "Nature & Hiking",     "sort_order": 7},
    {"key": "luxury",      "label": "Luxury Travel",       "sort_order": 8},
    {"key": "budget",      "label": "Budget Travel",       "sort_order": 9},
    {"key": "backpacking", "label": "Backpacking",         "sort_order": 10},
    {"key": "road_trips",  "label": "Road Trips",          "sort_order": 11},
    {"key": "cruises",     "label": "Cruises",             "sort_order": 12},
    {"key": "business",    "label": "Business Travel",     "sort_order": 13},
    {"key": "solo",        "label": "Solo Travel",         "sort_order": 14},
    {"key": "wellness",    "label": "Wellness & Spa",      "sort_order": 15},
    {"key": "festivals",   "label": "Festivals & Events",  "sort_order": 16},
    {"key": "sports",      "label": "Sports & Fitness",    "sort_order": 17},
    {"key": "nightlife",   "label": "Nightlife",           "sort_order": 18},
    {"key": "eco",         "label": "Eco-Tourism",         "sort_order": 19}
  ]'::jsonb),

  ('block_reason', '[
    {"key": "inappropriate", "label": "Inappropriate behavior", "sort_order": 1},
    {"key": "spam",          "label": "Spam",                   "sort_order": 2},
    {"key": "harassment",    "label": "Harassment",             "sort_order": 3},
    {"key": "fake_profile",  "label": "Fake profile",           "sort_order": 4},
    {"key": "other",         "label": "Other",                  "sort_order": 5}
  ]'::jsonb)

ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
