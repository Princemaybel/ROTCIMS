-- ============================================================================
-- FILE: create_modules_and_documents_storage.sql
-- PURPOSE: Provisions the 'documents' Storage Bucket and optimizes the
--          'documents' table for Cadet Learning Modules (Word, Excel, PDF, PPTX)
--          and Administrative Forms in ROTCIMS.
--
-- HOW TO RUN:
--   1. Open Supabase Dashboard (https://supabase.com/dashboard)
--   2. Click "SQL Editor" on the left menu -> "+ New Query"
--   3. Paste this entire file and click "RUN"
-- ============================================================================

-- 1. Create the public 'documents' storage bucket if it does not exist yet
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'documents',
  'documents',
  true,                  -- Public so cadets can directly download learning modules
  52428800,              -- 50 MB max file size per file
  ARRAY[
    -- Microsoft Word
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document', -- .docx
    'application/msword',                                                     -- .doc
    -- Microsoft Excel
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',      -- .xlsx
    'application/vnd.ms-excel',                                               -- .xls
    'text/csv',                                                               -- .csv
    -- Microsoft PowerPoint
    'application/vnd.openxmlformats-officedocument.presentationml.presentation', -- .pptx
    'application/vnd.ms-powerpoint',                                            -- .ppt
    -- PDF & Text
    'application/pdf',
    'text/plain',
    -- Compressed archives & images
    'application/zip',
    'application/x-zip-compressed',
    'application/vnd.rar',
    'image/png',
    'image/jpeg',
    'image/webp'
  ]
)
ON CONFLICT (id) DO UPDATE SET
  public = true,
  file_size_limit = 52428800,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 2. Storage RLS Policies for 'documents' bucket
-- Allow public / cadets to read and download files from the 'documents' bucket
DROP POLICY IF EXISTS "documents_bucket_public_read" ON storage.objects;
CREATE POLICY "documents_bucket_public_read"
  ON storage.objects FOR SELECT
  USING ( bucket_id = 'documents' );

-- Allow authenticated admins and personnel to upload files to 'documents' bucket
DROP POLICY IF EXISTS "documents_bucket_admin_upload" ON storage.objects;
CREATE POLICY "documents_bucket_admin_upload"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'documents'
    AND (
      auth.role() = 'authenticated'
      OR public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader')
    )
  );

-- Allow admins/personnel to update files in 'documents' bucket
DROP POLICY IF EXISTS "documents_bucket_admin_update" ON storage.objects;
CREATE POLICY "documents_bucket_admin_update"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'documents'
    AND (
      auth.role() = 'authenticated'
      OR public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader')
    )
  );

-- Allow admins to delete files from 'documents' bucket
DROP POLICY IF EXISTS "documents_bucket_admin_delete" ON storage.objects;
CREATE POLICY "documents_bucket_admin_delete"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'documents'
    AND (
      auth.role() = 'authenticated'
      OR public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader')
    )
  );

-- 3. Ensure 'documents' table exists and has all module fields
CREATE TABLE IF NOT EXISTS public.documents (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title            text NOT NULL,
  description      text,
  category         text NOT NULL DEFAULT 'Learning Modules',
  subject          text DEFAULT 'General Military Science',
  file_path        text NOT NULL,
  file_name        text NOT NULL,
  file_type        text NOT NULL DEFAULT 'application/octet-stream',
  file_size_bytes  bigint DEFAULT 0,
  is_published     boolean NOT NULL DEFAULT true,
  access_level     text NOT NULL DEFAULT 'all',
  uploaded_by      uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- Ensure columns exist if table was created with older schema
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='documents' AND column_name='description') THEN
    ALTER TABLE public.documents ADD COLUMN description text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='documents' AND column_name='subject') THEN
    ALTER TABLE public.documents ADD COLUMN subject text DEFAULT 'General Military Science';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='documents' AND column_name='access_level') THEN
    ALTER TABLE public.documents ADD COLUMN access_level text NOT NULL DEFAULT 'all';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='documents' AND column_name='file_path') THEN
    ALTER TABLE public.documents ADD COLUMN file_path text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='documents' AND column_name='file_name') THEN
    ALTER TABLE public.documents ADD COLUMN file_name text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='documents' AND column_name='file_type') THEN
    ALTER TABLE public.documents ADD COLUMN file_type text NOT NULL DEFAULT 'application/octet-stream';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='documents' AND column_name='file_size_bytes') THEN
    ALTER TABLE public.documents ADD COLUMN file_size_bytes bigint DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='documents' AND column_name='is_published') THEN
    ALTER TABLE public.documents ADD COLUMN is_published boolean NOT NULL DEFAULT true;
  END IF;
END $$;

-- 4. Enable RLS on documents table and create permissive policies
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cadets_and_public_read_documents" ON public.documents;
CREATE POLICY "cadets_and_public_read_documents"
  ON public.documents FOR SELECT
  USING (
    is_published = true
    OR public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader')
  );

DROP POLICY IF EXISTS "officers_manage_documents" ON public.documents;
CREATE POLICY "officers_manage_documents"
  ON public.documents FOR ALL
  USING (
    public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader')
    OR auth.role() = 'authenticated'
  );

-- 5. Helpful index for rapid query execution
CREATE INDEX IF NOT EXISTS idx_documents_category_created ON public.documents(category, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_documents_published ON public.documents(is_published, access_level);

