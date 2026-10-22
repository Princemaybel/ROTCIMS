-- ============================================================================
-- FILE: create_gallery_storage_bucket.sql
-- PURPOSE: Creates the 'gallery' Supabase Storage bucket for hosting
--          uploaded photo files from the Admin Posting Center.
--          After running this, images uploaded via the composer will be stored
--          as real public URLs (not base64), so they appear in gallery.html.
-- HOW TO RUN: Open Supabase Dashboard > SQL Editor > paste and run this file.
-- ============================================================================

-- ── Create the public 'gallery' storage bucket ──────────────────────────────
-- "public = true" means files are accessible via a public URL without auth.
-- This is what allows gallery.html to load the images as <img> tags.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'gallery',                                        -- Bucket ID (used in JS code)
  'gallery',                                        -- Bucket display name
  true,                                             -- Public: URLs work without login
  10485760,                                         -- 10 MB max file size per image
  ARRAY['image/jpeg','image/png','image/webp','image/gif','image/heic']
)
ON CONFLICT (id) DO UPDATE SET
  public             = EXCLUDED.public,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ── Storage RLS Policies ─────────────────────────────────────────────────────

-- 1. Allow anyone to READ (download) files from the gallery bucket
--    This is what allows gallery.html's <img src="..."> to work publicly.
DROP POLICY IF EXISTS "gallery_public_read" ON storage.objects;
CREATE POLICY "gallery_public_read"
  ON storage.objects FOR SELECT
  USING ( bucket_id = 'gallery' );

-- 2. Allow authenticated admins/personnel to UPLOAD new files
DROP POLICY IF EXISTS "gallery_admin_upload" ON storage.objects;
CREATE POLICY "gallery_admin_upload"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'gallery'
    AND public.current_profile_role() IN ('admin', 'personnel')
  );

-- 3. Allow authenticated admins/personnel to DELETE their files
DROP POLICY IF EXISTS "gallery_admin_delete" ON storage.objects;
CREATE POLICY "gallery_admin_delete"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'gallery'
    AND public.current_profile_role() IN ('admin', 'personnel')
  );

-- 4. Allow authenticated admins/personnel to UPDATE (replace) files
DROP POLICY IF EXISTS "gallery_admin_update" ON storage.objects;
CREATE POLICY "gallery_admin_update"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'gallery'
    AND public.current_profile_role() IN ('admin', 'personnel')
  );

-- ── Also add posts table (if not yet created) ────────────────────────────────
-- Run this only if create_posts_table.sql hasn't been applied yet.
-- The posts table stores: title, caption, category, images (jsonb URL array),
-- album_name, event_date, location, uniform_info, is_published.

CREATE TABLE IF NOT EXISTS public.posts (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  title        text        NOT NULL,
  caption      text        NOT NULL,
  category     text        NOT NULL CHECK (category IN ('gallery','events','announcements','requirements')),
  images       jsonb       NOT NULL DEFAULT '[]'::jsonb,  -- Array of Storage public URLs
  album_name   text,
  event_date   date,
  location     text,
  uniform_info text,
  priority     text        DEFAULT 'normal',
  is_published boolean     NOT NULL DEFAULT true,
  created_by   uuid        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS posts_created_at_idx ON public.posts(created_at DESC);
CREATE INDEX IF NOT EXISTS posts_category_idx   ON public.posts(category);

ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "posts_select_published" ON public.posts;
CREATE POLICY "posts_select_published" ON public.posts FOR SELECT USING (
  is_published = true OR public.current_profile_role() IN ('admin','personnel')
);

DROP POLICY IF EXISTS "posts_manage_admin" ON public.posts;
CREATE POLICY "posts_manage_admin" ON public.posts FOR ALL USING (
  public.current_profile_role() IN ('admin','personnel')
);

