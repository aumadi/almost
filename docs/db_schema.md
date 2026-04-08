# Almost App — Database Schema

## Overview

**Almost** is a travel connection app. Users add trips (with departure, optional layover, and arrival airports + dates) and are matched ("crossed paths") with other travelers who share the same airport on the same date with the same connection intent. They can view each other's profiles, send connection requests with a brief note, and once connected, chat.

**Stack:** FlutterFlow (frontend) + Supabase (backend). No custom API server. All data access via Supabase auto-generated REST APIs and PostgREST. Business logic (RPC functions, Edge Functions, triggers) is out of scope for this schema doc.

---

## Enums

| Enum | Values | Used In |
|------|--------|---------|
| `connection_type` | `romantic`, `platonic`, `professional` | `trips.connection_type`, `trip_overlaps.connection_type` |
| `connection_request_status` | `pending`, `accepted`, `declined` | `connection_requests.status` |
| `notification_type` | `connection_request_received`, `connection_accepted`, `new_message`, `trip_starts_tomorrow` | `notifications.type` |
| `open_to` | `men`, `women`, `both` | `profiles.open_to` |

---

## Tables

### 1. `airports`

Reference/seed table of IATA airports. Populated at migration time — not user-created data.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `iata_code` | text | NOT NULL, UNIQUE | 3-letter IATA code (e.g. `SFO`) |
| `icao_code` | text | nullable | 4-letter ICAO code (e.g. `KSFO`) |
| `name` | text | NOT NULL | Full airport name |
| `city` | text | NOT NULL | City name |
| `country` | text | NOT NULL | Country name |
| `country_code` | text | NOT NULL | ISO 3166-1 alpha-2 (e.g. `US`) |
| `latitude` | numeric(9,6) | nullable | |
| `longitude` | numeric(9,6) | nullable | |
| `timezone` | text | nullable | IANA timezone (e.g. `America/Los_Angeles`) |
| `is_active` | boolean | NOT NULL, DEFAULT true | Soft-disable airports without deleting |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `updated_at` | timestamptz | NOT NULL, DEFAULT now() | |

**Notes:** No `created_by`, `deleted_at` — reference data, not user-owned rows. Seeded with ~100 major global airports in the migration.

---

### 2. `app_settings`

Admin-managed option lists used throughout the app. One row = one selectable option in a dropdown or multi-select.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `updated_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `created_by` | uuid | → auth.users(id) ON DELETE SET NULL, nullable | |
| `category` | text | NOT NULL | See categories below |
| `value` | text | NOT NULL | Machine-readable key (e.g. `non_binary`) |
| `label` | text | NOT NULL | Display text (e.g. `Non-binary`) |
| `sort_order` | integer | NOT NULL, DEFAULT 0 | Controls dropdown order |
| `is_active` | boolean | NOT NULL, DEFAULT true | Hide from UI without deleting |
| `deleted_at` | timestamptz | nullable | Soft delete |

**UNIQUE constraint:** `(category, value)`

**Categories and their seed values:**

| Category | Seed Values |
|----------|-------------|
| `age_range` | 18–24, 25–30, 31–35, 36–40, 41–50, 51+ |
| `gender_identity` | Man, Woman, Non-binary, Genderfluid, Agender, Other, Prefer not to say |
| `pronouns` | He/Him, She/Her, They/Them, He/They, She/They, Any pronouns, Prefer not to say |
| `education` | High School, Some College, Associate's, Bachelor's, Master's, Doctorate, Trade School, Prefer not to say |
| `ethnicity` | Asian, Black / African American, Hispanic / Latino, Middle Eastern, Native American, Pacific Islander, White / Caucasian, Mixed, Prefer not to say, Other |
| `interest` | Adventure Travel, Beach Lover, City Explorer, Food & Dining, Culture & History, Photography, Nature & Hiking, Luxury Travel, Budget Travel, Backpacking, Road Trips, Cruises, Business Travel, Solo Travel, Wellness & Spa, Festivals & Events, Sports & Fitness, Nightlife, Eco-Tourism |
| `block_reason` | Inappropriate behavior, Spam, Harassment, Fake profile, Other |

---

### 3. `profiles`

Extends `auth.users` with all app-specific user data. The profile `id` IS the auth user's ID — no separate UUID.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK → auth.users(id) ON DELETE CASCADE | Shared with auth user |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `updated_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `first_name` | text | nullable | |
| `last_name` | text | nullable | |
| `age_range_id` | uuid | → app_settings(id) ON DELETE SET NULL, nullable | category = `age_range` |
| `height_cm` | numeric(5,1) | nullable | Always stored in cm; UI converts to ft/cm for display |
| `gender_identity_id` | uuid | → app_settings(id) ON DELETE SET NULL, nullable | category = `gender_identity` |
| `pronouns_id` | uuid | → app_settings(id) ON DELETE SET NULL, nullable | category = `pronouns` |
| `education_id` | uuid | → app_settings(id) ON DELETE SET NULL, nullable | category = `education` |
| `ethnicity_id` | uuid | → app_settings(id) ON DELETE SET NULL, nullable | category = `ethnicity` |
| `open_to` | text | nullable, CHECK IN ('men','women','both') | Gender preference; stored but not used for overlap filtering in v1 |
| `bio` | text | nullable | Short 2–3 sentence bio |
| `profile_complete` | boolean | NOT NULL, DEFAULT false | Set to true once user finishes the profile + preferences flow |
| `deleted_at` | timestamptz | nullable | Soft delete; anonymization trigger fires on transition NULL → value |

**Notes:**
- No `created_by` column — `id` itself is the user reference.
- Auto-created via trigger on `auth.users` INSERT.
- Anonymization trigger scrubs PII fields when `deleted_at` is set.

---

### 4. `profile_photos`

Stores up to 3 profile photos per user. `display_order = 1` is always the primary photo shown in cards and chat headers.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `updated_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `created_by` | uuid | → auth.users(id) ON DELETE SET NULL, nullable | |
| `profile_id` | uuid | NOT NULL → profiles(id) ON DELETE CASCADE | |
| `storage_path` | text | NOT NULL | Supabase Storage path (e.g. `profile-photos/user-id/1.jpg`) |
| `display_order` | integer | NOT NULL, DEFAULT 1 | 1 = primary; max 3 enforced at app level |
| `deleted_at` | timestamptz | nullable | |

**UNIQUE constraint:** `(profile_id, display_order)`

**Storage bucket:** `profile-photos` (public read, authenticated write)

---

### 5. `profile_interests`

Junction table linking profiles to their selected interests from `app_settings`. Max 5 per user, enforced at the app level.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `profile_id` | uuid | NOT NULL → profiles(id) ON DELETE CASCADE | |
| `setting_id` | uuid | NOT NULL → app_settings(id) ON DELETE CASCADE | Must have category = `interest` |

**UNIQUE constraint:** `(profile_id, setting_id)`

**Notes:** Junction table — no `updated_at`, `created_by`, `deleted_at`. Rows are deleted directly when a user removes an interest.

---

### 6. `trips`

A user's travel plan. Each trip has departure, optional layover, and arrival. The matching algorithm uses airports + dates + connection type to find overlaps.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `updated_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `created_by` | uuid | NOT NULL → auth.users(id) ON DELETE CASCADE | The trip owner |
| `departure_airport_id` | uuid | NOT NULL → airports(id) | |
| `departure_date` | date | NOT NULL | |
| `layover_airport_id` | uuid | → airports(id), nullable | |
| `layover_date` | date | nullable | Required if layover_airport_id is set |
| `arrival_airport_id` | uuid | NOT NULL → airports(id) | |
| `arrival_date` | date | NOT NULL | |
| `connection_type` | connection_type | NOT NULL | `romantic`, `platonic`, or `professional` — one per trip |
| `deleted_at` | timestamptz | nullable | |

**Notes:**
- ON DELETE CASCADE on `created_by` ensures trips are removed when the user's auth account is deleted.
- Only 1 layover supported in v1 (schema supports adding more layover tables later).
- Departure and arrival can span different dates — whatever the user enters.

---

### 7. `trip_overlaps`

Stores computed matches between two trips. Populated by business logic (trigger/RPC) when a trip is created or updated. A row exists here when two trips share the same airport on the same date with the same connection type.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `user_a_id` | uuid | NOT NULL → profiles(id) ON DELETE CASCADE | Trip A's owner |
| `user_b_id` | uuid | NOT NULL → profiles(id) ON DELETE CASCADE | Trip B's owner |
| `trip_a_id` | uuid | NOT NULL → trips(id) ON DELETE CASCADE | |
| `trip_b_id` | uuid | NOT NULL → trips(id) ON DELETE CASCADE | |
| `matched_airport_id` | uuid | NOT NULL → airports(id) | The airport where paths cross |
| `overlap_date` | date | NOT NULL | The date of the shared airport visit |
| `connection_type` | connection_type | NOT NULL | Same for both trips (filter condition) |
| `deleted_at` | timestamptz | nullable | Soft-deleted when either trip is deleted |

**UNIQUE constraint:** `(trip_a_id, trip_b_id, matched_airport_id, overlap_date)`

**Notes:**
- `user_a_id` / `user_b_id` are denormalized from the trips for efficient RLS and query performance.
- Two trips can generate multiple overlap rows if they share more than one airport (e.g., same layover AND same arrival).
- The FlutterFlow "Crossed Paths" home screen queries this table filtered by `user_a_id = me OR user_b_id = me`.

---

### 8. `connection_requests`

Sent when user A taps "Connect" on a profile card, optionally including a brief note. User B can accept or decline.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `updated_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `created_by` | uuid | NOT NULL → auth.users(id) ON DELETE CASCADE | The sender |
| `recipient_id` | uuid | NOT NULL → profiles(id) ON DELETE CASCADE | The receiver |
| `brief_note` | text | nullable | Optional intro message sent with the request |
| `status` | connection_request_status | NOT NULL, DEFAULT 'pending' | `pending`, `accepted`, `declined` |
| `deleted_at` | timestamptz | nullable | |

**UNIQUE constraint:** `(created_by, recipient_id)` — one lifetime request per pair. Once sent, no re-requesting regardless of outcome.

**Notes:**
- When `status` changes to `accepted`, business logic creates a `chats` row for this pair.

---

### 9. `chats`

One chat per user pair, regardless of how many trip overlaps they share. Created when a connection request is accepted.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `updated_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `user_a_id` | uuid | NOT NULL → profiles(id) ON DELETE CASCADE | |
| `user_b_id` | uuid | NOT NULL → profiles(id) ON DELETE CASCADE | |
| `last_message_at` | timestamptz | nullable | Denormalized for sorting the chat list; updated by business logic on new message |
| `deleted_at` | timestamptz | nullable | |

**UNIQUE index:** `LEAST(user_a_id::text, user_b_id::text), GREATEST(user_a_id::text, user_b_id::text)` — ensures exactly 1 chat per pair regardless of which user is A or B.

---

### 10. `messages`

Messages sent within a chat.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `updated_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `created_by` | uuid | NOT NULL → auth.users(id) ON DELETE CASCADE | The sender |
| `chat_id` | uuid | NOT NULL → chats(id) ON DELETE CASCADE | |
| `content` | text | NOT NULL | Message text |
| `is_read` | boolean | NOT NULL, DEFAULT false | Flipped to true when the recipient opens the chat |
| `deleted_at` | timestamptz | nullable | |

---

### 11. `notifications`

In-app notifications for the 4 supported types. Shown on the Notifications screen with today/last week grouping.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `updated_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `user_id` | uuid | NOT NULL → profiles(id) ON DELETE CASCADE | Recipient of the notification |
| `type` | notification_type | NOT NULL | See enum above |
| `related_user_id` | uuid | → profiles(id) ON DELETE SET NULL, nullable | For request/accepted/message types |
| `related_trip_id` | uuid | → trips(id) ON DELETE SET NULL, nullable | For `trip_starts_tomorrow` type |
| `related_chat_id` | uuid | → chats(id) ON DELETE SET NULL, nullable | For `new_message` type |
| `is_read` | boolean | NOT NULL, DEFAULT false | |
| `deleted_at` | timestamptz | nullable | |

---

### 12. `user_blocks`

When a user blocks another. Block reasons come from `app_settings` category `block_reason`.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `created_at` | timestamptz | NOT NULL, DEFAULT now() | |
| `created_by` | uuid | NOT NULL → auth.users(id) ON DELETE CASCADE | The blocker |
| `blocked_user_id` | uuid | NOT NULL → profiles(id) ON DELETE CASCADE | The blocked user |
| `reason_id` | uuid | → app_settings(id) ON DELETE SET NULL, nullable | category = `block_reason` |

**UNIQUE constraint:** `(created_by, blocked_user_id)` — can't block the same person twice.

**Notes:** Junction-style table — no `updated_at`, `deleted_at`. To unblock, the row is hard-deleted.

---

## Views

| View | Based On | Filters |
|------|----------|---------|
| `active_profiles` | `profiles` | `deleted_at IS NULL` |
| `active_trips` | `trips` | `deleted_at IS NULL` |
| `active_trip_overlaps` | `trip_overlaps` | `deleted_at IS NULL` |
| `active_connection_requests` | `connection_requests` | `deleted_at IS NULL` |
| `active_chats` | `chats` | `deleted_at IS NULL` |
| `active_messages` | `messages` | `deleted_at IS NULL` |
| `active_notifications` | `notifications` | `deleted_at IS NULL` |
| `active_app_settings` | `app_settings` | `deleted_at IS NULL AND is_active = true` |

**Note:** FlutterFlow should query the `active_*` views for all normal operations. The base tables are only accessed for admin/background operations.

---

## Relationships

| From | Column | To | On Delete |
|------|--------|----|-----------|
| `profiles` | `id` | `auth.users(id)` | CASCADE |
| `profiles` | `age_range_id` | `app_settings(id)` | SET NULL |
| `profiles` | `gender_identity_id` | `app_settings(id)` | SET NULL |
| `profiles` | `pronouns_id` | `app_settings(id)` | SET NULL |
| `profiles` | `education_id` | `app_settings(id)` | SET NULL |
| `profiles` | `ethnicity_id` | `app_settings(id)` | SET NULL |
| `profile_photos` | `profile_id` | `profiles(id)` | CASCADE |
| `profile_interests` | `profile_id` | `profiles(id)` | CASCADE |
| `profile_interests` | `setting_id` | `app_settings(id)` | CASCADE |
| `trips` | `created_by` | `auth.users(id)` | CASCADE |
| `trips` | `departure_airport_id` | `airports(id)` | RESTRICT |
| `trips` | `layover_airport_id` | `airports(id)` | RESTRICT |
| `trips` | `arrival_airport_id` | `airports(id)` | RESTRICT |
| `trip_overlaps` | `user_a_id` | `profiles(id)` | CASCADE |
| `trip_overlaps` | `user_b_id` | `profiles(id)` | CASCADE |
| `trip_overlaps` | `trip_a_id` | `trips(id)` | CASCADE |
| `trip_overlaps` | `trip_b_id` | `trips(id)` | CASCADE |
| `trip_overlaps` | `matched_airport_id` | `airports(id)` | RESTRICT |
| `connection_requests` | `created_by` | `auth.users(id)` | CASCADE |
| `connection_requests` | `recipient_id` | `profiles(id)` | CASCADE |
| `chats` | `user_a_id` | `profiles(id)` | CASCADE |
| `chats` | `user_b_id` | `profiles(id)` | CASCADE |
| `messages` | `chat_id` | `chats(id)` | CASCADE |
| `messages` | `created_by` | `auth.users(id)` | CASCADE |
| `notifications` | `user_id` | `profiles(id)` | CASCADE |
| `notifications` | `related_user_id` | `profiles(id)` | SET NULL |
| `notifications` | `related_trip_id` | `trips(id)` | SET NULL |
| `notifications` | `related_chat_id` | `chats(id)` | SET NULL |
| `user_blocks` | `created_by` | `auth.users(id)` | CASCADE |
| `user_blocks` | `blocked_user_id` | `profiles(id)` | CASCADE |
| `user_blocks` | `reason_id` | `app_settings(id)` | SET NULL |

---

## Indexes

| Index | Table | Columns | Purpose |
|-------|-------|---------|---------|
| `idx_profiles_age_range_id` | `profiles` | `age_range_id` | FK lookup |
| `idx_profiles_gender_identity_id` | `profiles` | `gender_identity_id` | FK lookup |
| `idx_trips_created_by` | `trips` | `created_by` | User's own trips query (Trips screen) |
| `idx_trips_departure_airport_date` | `trips` | `departure_airport_id, departure_date` | Overlap matching |
| `idx_trips_layover_airport_date` | `trips` | `layover_airport_id, layover_date` WHERE `layover_airport_id IS NOT NULL` | Overlap matching |
| `idx_trips_arrival_airport_date` | `trips` | `arrival_airport_id, arrival_date` | Overlap matching |
| `idx_trip_overlaps_user_a` | `trip_overlaps` | `user_a_id` WHERE `deleted_at IS NULL` | Crossed paths query |
| `idx_trip_overlaps_user_b` | `trip_overlaps` | `user_b_id` WHERE `deleted_at IS NULL` | Crossed paths query |
| `idx_trip_overlaps_trip_a` | `trip_overlaps` | `trip_a_id` | FK lookup |
| `idx_trip_overlaps_trip_b` | `trip_overlaps` | `trip_b_id` | FK lookup |
| `idx_connection_requests_created_by` | `connection_requests` | `created_by` WHERE `deleted_at IS NULL` | Sent requests query |
| `idx_connection_requests_recipient` | `connection_requests` | `recipient_id, status` WHERE `deleted_at IS NULL` | Received requests query |
| `idx_chats_user_a` | `chats` | `user_a_id` WHERE `deleted_at IS NULL` | User's chats list |
| `idx_chats_user_b` | `chats` | `user_b_id` WHERE `deleted_at IS NULL` | User's chats list |
| `idx_chats_last_message_at` | `chats` | `last_message_at DESC` WHERE `deleted_at IS NULL` | Sort chat list by recency |
| `idx_messages_chat_id` | `messages` | `chat_id, created_at DESC` WHERE `deleted_at IS NULL` | Chat message history |
| `idx_messages_unread` | `messages` | `chat_id` WHERE `is_read = false AND deleted_at IS NULL` | Unread count |
| `idx_notifications_user_unread` | `notifications` | `user_id, created_at DESC` WHERE `is_read = false AND deleted_at IS NULL` | Notifications screen |
| `idx_user_blocks_created_by` | `user_blocks` | `created_by` | My blocks list |
| `idx_user_blocks_blocked_user` | `user_blocks` | `blocked_user_id` | Check if I'm blocked |
| `idx_app_settings_category` | `app_settings` | `category, sort_order` WHERE `deleted_at IS NULL AND is_active = true` | Load dropdown options |
| `idx_airports_iata_code` | `airports` | `iata_code` | Airport search by code |

---

## RLS Summary

| Table | SELECT | INSERT | UPDATE | DELETE |
|-------|--------|--------|--------|--------|
| `airports` | All authenticated users | No one (seed data only) | No one | No one |
| `app_settings` | All authenticated users | No one (admin only via SQL) | No one | No one |
| `profiles` | All authenticated users (all non-deleted profiles) | No one (auto-created by trigger) | Own profile only (`id = auth.uid()`) | Restricted (soft delete only) |
| `profile_photos` | All authenticated users | Own photos only | Own photos only | Own photos only |
| `profile_interests` | All authenticated users | Own interests only | N/A | Own interests only |
| `trips` | Own trips + trips referenced in `trip_overlaps` where I'm a participant | Own trips only | Own trips only | Restricted (soft delete only) |
| `trip_overlaps` | Where `user_a_id = me OR user_b_id = me` | No one (populated by triggers/RPCs) | No one | No one |
| `connection_requests` | Where `created_by = me OR recipient_id = me` | Own requests only (`created_by = auth.uid()`) | Recipient can update status; sender cannot | Restricted |
| `chats` | Where `user_a_id = me OR user_b_id = me` | No one (created by business logic on acceptance) | No one directly | No one |
| `messages` | Messages in my chats | Into my chats only | Own messages only | No one (soft delete) |
| `notifications` | Own notifications only (`user_id = me`) | No one (created by business logic) | Own notifications (mark as read) | No one |
| `user_blocks` | Own blocks only (`created_by = me`) | Own blocks only | No one | Own blocks only (hard delete = unblock) |

---

## Storage Buckets

| Bucket | Access | Used By |
|--------|--------|---------|
| `profile-photos` | Public read, authenticated write (own folder only) | `profile_photos.storage_path` |

**Path convention:** `profile-photos/{user_id}/{display_order}.{ext}` (e.g. `profile-photos/abc-123/1.jpg`)

---

## Design Notes & Trade-offs

1. **trip_overlaps populated by business logic** — The overlap computation (find trips sharing airport + date + connection_type) is done by a trigger or RPC function (not in this schema). The `trip_overlaps` table is where results land. FlutterFlow reads directly from this table.

2. **1 chat per user pair** — Enforced via a functional unique index on `LEAST/GREATEST(user_a_id, user_b_id)`. The chat header "SFO, MARCH 10–12" context is derived at query time by joining through `trip_overlaps` — it is not stored on the chat.

3. **open_to not used for filtering yet** — Stored in profiles for future use; v1 overlap matching only uses airport, date, and connection_type.

4. **No subscription/payments tables** — Explicitly out of scope for v1.

5. **No admin panel tables** — Out of scope for v1; user blocks and app_settings provide basic content governance.

6. **airports RESTRICT on delete** — Airport rows should never be deleted if trips reference them; use `is_active = false` to retire airports instead.

7. **height stored in cm** — The UI shows ft/cm toggle; always store in cm and let the frontend convert. Avoids dual-column confusion.

8. **profile_complete flag** — Needed because the profile setup has a "Save and skip" option, leaving profiles potentially incomplete. Business logic should gate certain features (e.g., appearing in crossed paths) behind `profile_complete = true`.

9. **Future multi-layover support** — The current schema has `layover_airport_id` and `layover_date` directly on `trips`. To support multiple layovers, a `trip_legs` table would be introduced and the direct columns deprecated. For now, the single-layover design is clean and sufficient.
