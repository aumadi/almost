-- =============================================================================
-- Fix profile-photos bucket: make public + fix RLS policies
-- =============================================================================

-- Make bucket public (fixes 400 on image URLs)
UPDATE storage.buckets
SET public = true
WHERE id = 'profile-photos';

-- Drop old policies and recreate cleanly
DROP POLICY IF EXISTS "profile_photos_select" ON storage.objects;
DROP POLICY IF EXISTS "profile_photos_insert" ON storage.objects;
DROP POLICY IF EXISTS "profile_photos_update" ON storage.objects;
DROP POLICY IF EXISTS "profile_photos_delete" ON storage.objects;

-- Public read (bucket is public, this covers API access too)
CREATE POLICY "profile_photos_select"
  ON storage.objects FOR SELECT
  TO public
  USING (bucket_id = 'profile-photos');

-- Upload: path must start with the user's own UUID folder
-- FlutterFlow upload path must be: {user_id}/{display_order}.jpg
CREATE POLICY "profile_photos_insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'profile-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Replace/update own photos only
CREATE POLICY "profile_photos_update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'profile-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Delete own photos only
CREATE POLICY "profile_photos_delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'profile-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
