-- =============================================================================
-- Storage: profile-photos bucket
-- Path pattern: profile-photos/{user_id}/{display_order}.{ext}
-- Max 3 photos per user (enforced at app level).
-- =============================================================================

-- Create bucket (private — URLs served via signed URLs or RLS-controlled downloads)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'profile-photos',
  'profile-photos',
  false,
  5242880,                                          -- 5 MB max per file
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- RLS policies for storage.objects
-- -----------------------------------------------------------------------------

-- Users can read any profile photo (needed to view other profiles)
CREATE POLICY "profile_photos_select"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'profile-photos');

-- Users can upload only into their own folder
CREATE POLICY "profile_photos_insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'profile-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Users can update (replace) only their own photos
CREATE POLICY "profile_photos_update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'profile-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Users can delete only their own photos
CREATE POLICY "profile_photos_delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'profile-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
