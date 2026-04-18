-- =============================================================================
-- Airports: replace old schema with full CSV-compatible schema
-- Old columns dropped; trips FK updated to match new structure.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Drop FK constraints on trips and trip_overlaps that reference airports
-- -----------------------------------------------------------------------------
ALTER TABLE public.trips
  DROP CONSTRAINT IF EXISTS trips_departure_airport_id_fkey,
  DROP CONSTRAINT IF EXISTS trips_layover_airport_id_fkey,
  DROP CONSTRAINT IF EXISTS trips_arrival_airport_id_fkey;

ALTER TABLE public.trip_overlaps
  DROP CONSTRAINT IF EXISTS trip_overlaps_matched_airport_id_fkey;

-- -----------------------------------------------------------------------------
-- 2. Drop old airports table (seed data included)
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS set_updated_at_airports ON public.airports;
DROP INDEX   IF EXISTS idx_airports_iata;
DROP TABLE   IF EXISTS public.airports;

-- -----------------------------------------------------------------------------
-- 3. Create new airports table
-- -----------------------------------------------------------------------------
CREATE TABLE public.airports (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  -- CSV-mapped columns
  csv_id            text,
  ident             text,
  type              text,                   -- large_airport, medium_airport, small_airport, heliport, closed, etc.
  name              text        NOT NULL,
  latitude          numeric(11,7),
  longitude         numeric(11,7),
  elevation_ft      numeric,
  continent         text,                   -- AF, AN, AS, EU, NA, OC, SA
  iso_country       text,                   -- ISO 3166-1 alpha-2, e.g. 'US'
  iso_region        text,                   -- ISO 3166-2, e.g. 'US-CA'
  city              text,
  scheduled_service text,                   -- 'yes' / 'no'
  icao_code         text,
  iata_code         text        NOT NULL UNIQUE,
  gps_code          text,
  local_code        text,
  home_link         text,
  wikipedia_link    text,
  keywords          text,

  -- Custom field
  is_active         boolean     NOT NULL DEFAULT true
);

-- -----------------------------------------------------------------------------
-- 4. Indexes
-- -----------------------------------------------------------------------------
CREATE INDEX idx_airports_iata_code ON public.airports (iata_code) WHERE iata_code IS NOT NULL;
CREATE INDEX idx_airports_icao_code ON public.airports (icao_code) WHERE icao_code IS NOT NULL;
CREATE INDEX idx_airports_type      ON public.airports (type);
CREATE INDEX idx_airports_country   ON public.airports (iso_country);

-- -----------------------------------------------------------------------------
-- 5. Restore FK constraints on trips and trip_overlaps
-- -----------------------------------------------------------------------------
ALTER TABLE public.trips
  ADD CONSTRAINT trips_departure_airport_id_fkey
    FOREIGN KEY (departure_airport_id) REFERENCES public.airports(id) ON DELETE RESTRICT,
  ADD CONSTRAINT trips_layover_airport_id_fkey
    FOREIGN KEY (layover_airport_id)   REFERENCES public.airports(id) ON DELETE RESTRICT,
  ADD CONSTRAINT trips_arrival_airport_id_fkey
    FOREIGN KEY (arrival_airport_id)   REFERENCES public.airports(id) ON DELETE RESTRICT;

ALTER TABLE public.trip_overlaps
  ADD CONSTRAINT trip_overlaps_matched_airport_id_fkey
    FOREIGN KEY (matched_airport_id) REFERENCES public.airports(id) ON DELETE RESTRICT;

-- -----------------------------------------------------------------------------
-- 6. RLS
-- -----------------------------------------------------------------------------
ALTER TABLE public.airports ENABLE ROW LEVEL SECURITY;

CREATE POLICY airports_select_all
  ON public.airports FOR SELECT
  TO authenticated
  USING (true);
