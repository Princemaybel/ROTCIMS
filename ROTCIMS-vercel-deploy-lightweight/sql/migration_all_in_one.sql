-- ============================================================================
-- FILE: migration_all_in_one.sql
-- PROJECT: ROTCIMS — Reserve Officers' Training Corps Information Management System
--
-- PURPOSE:
--   This is the MASTER MIGRATION script. It applies all incremental changes
--   on top of an already-deployed base schema (supabase_schema.sql). Run this
--   when you need to add the 'personnel' role tier, the documents library, or
--   update RLS policies without dropping and recreating the whole database.
--
-- HOW TO RUN:
--   1. Open the Supabase Dashboard for your project.
--   2. Navigate to: Database > SQL Editor > + New Query
--      (or visit https://supabase.com/dashboard/project/_/sql/new)
--   3. Paste this entire file and click "Run".
--   4. All statements use IF NOT EXISTS / ON CONFLICT guards, so it is SAFE
--      to run more than once (idempotent).
--
-- WHAT THIS SCRIPT DOES (in order):
--   PART 1 — Extends the 'profiles' role constraint to include 'personnel'
--             and 'platoon_leader', and adds 'company'/'platoon' columns.
--   PART 2 — Creates the 'personnel' table for extended officer information.
--   PART 3 — Creates the 'documents' table and the private storage bucket.
--   PART 4 — Recreates RLS policies across all tables for the 3-tier
--             access model: cadet | personnel/platoon_leader | admin.
--   PART 5 — Seeds fictional development data (announcements, sessions,
--             documents) so the UI is not empty during development.
-- ============================================================================

-- ============================================================
-- PART 1: Role Constraint & Profile Columns
-- Supabase stores the user's role in the 'profiles' table.
-- The CHECK constraint enforces that only known role strings
-- can be inserted — this prevents typos or unauthorized roles.
-- ============================================================

-- Remove the old constraint (it only allowed 'admin' and 'cadet').
-- IF EXISTS means this won't fail if the constraint was never created.
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_role_check;

-- Re-add the constraint with the full 4-role set.
-- 'cadet'         — enrolled ROTC student (lowest privilege)
-- 'personnel'     — ROTC staff / officer  (mid-tier privilege)
-- 'platoon_leader'— cadet officer leading a platoon (mid-tier)
-- 'admin'         — commandant / system administrator (full access)
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role IN ('cadet', 'personnel', 'platoon_leader', 'admin'));

-- Add optional organisational placement columns to profiles.
-- 'company' — which company (Alpha, Bravo, etc.) the user belongs to
-- 'platoon' — which platoon within that company
-- ADD COLUMN IF NOT EXISTS is safe to run repeatedly without error.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS company text,
  ADD COLUMN IF NOT EXISTS platoon text;

-- ============================================================
-- PART 2: Personnel Table
-- Stores extended service information for users with a
-- 'personnel' or 'platoon_leader' role. This is a 1-to-1
-- extension of 'profiles' (one personnel record per profile).
-- ============================================================
CREATE TABLE IF NOT EXISTS public.personnel (
  -- Surrogate primary key; gen_random_uuid() uses pgcrypto to produce a UUID v4
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Links back to the profile that owns this personnel record.
  -- UNIQUE enforces the 1-to-1 relationship (each profile has at most one record).
  -- ON DELETE CASCADE means deleting the profile also deletes this row automatically.
  profile_id    uuid NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE CASCADE,

  -- Military rank of the officer (e.g., "Captain", "1LT")
  rank          text NOT NULL DEFAULT '',

  -- Duty position within the unit (e.g., "Commandant", "S3 Officer")
  position      text,

  -- The company or unit they are assigned to manage
  assigned_unit text,

  -- When this officer was formally appointed / assigned to their position
  appointed_at  timestamptz,

  -- Automatic audit timestamps — set once on insert, updated on change
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Index on profile_id so lookups like "get personnel record for this user"
-- are fast O(log n) rather than a slow full-table scan.
CREATE INDEX IF NOT EXISTS personnel_profile_idx ON public.personnel(profile_id);

-- RLS must be explicitly enabled per table in Supabase.
-- Without this line, ALL rows are visible to ALL authenticated users!
ALTER TABLE public.personnel ENABLE ROW LEVEL SECURITY;

-- -- RLS POLICY: personnel_select_personnel_or_admin --
-- Who can SELECT (read) rows from personnel?
--   • Any user whose role is 'personnel', 'platoon_leader', or 'admin'
--     (they need to see all staff records for management purposes), OR
--   • A cadet who owns that personnel record (e.g., a platoon_leader
--     reading their own profile). Achieved by checking whether their
--     auth.uid() matches through the profiles table.
DROP POLICY IF EXISTS "personnel_select_personnel_or_admin" ON public.personnel;
CREATE POLICY "personnel_select_personnel_or_admin"
  ON public.personnel
  FOR SELECT
  USING (
    public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')
    OR profile_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
  );

-- -- RLS POLICY: admin_manage_personnel --
-- Who can INSERT / UPDATE / DELETE any personnel row?
--   • Only 'admin'. The FOR ALL shorthand covers all write operations.
--   USING  — filters which existing rows the admin can touch.
--   WITH CHECK — validates new/modified data before writing.
DROP POLICY IF EXISTS "admin_manage_personnel" ON public.personnel;
CREATE POLICY "admin_manage_personnel"
  ON public.personnel
  FOR ALL
  USING (public.current_profile_role() = 'admin')
  WITH CHECK (public.current_profile_role() = 'admin');

-- -- RLS POLICY: personnel_update_own --
-- Allows a personnel/platoon_leader user to update THEIR OWN record only.
-- This lets them edit their own rank or position without admin involvement,
-- while preventing them from modifying other officers' records.
DROP POLICY IF EXISTS "personnel_update_own" ON public.personnel;
CREATE POLICY "personnel_update_own"
  ON public.personnel
  FOR UPDATE
  USING (profile_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid()))
  WITH CHECK (profile_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid()));

-- ============================================================
-- PART 3: Documents Table & Storage Bucket
-- The 'documents' table is a metadata registry for files
-- uploaded to Supabase Storage. The actual binary files live
-- in the 'documents' storage bucket; this table stores their
-- titles, categories, access rules, and storage paths.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.documents (
  -- Surrogate primary key
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Human-readable title shown in the document library UI
  title            text NOT NULL,

  -- Optional longer explanation of the document's contents
  description      text,

  -- Logical grouping for filtering (e.g., 'Forms', 'Memoranda', 'References')
  category         text NOT NULL DEFAULT 'General',

  -- Path inside the Supabase Storage bucket (used to generate a signed URL)
  file_path        text NOT NULL,

  -- Original filename shown to the user when downloading
  file_name        text NOT NULL,

  -- MIME type (e.g., 'application/pdf', 'image/png') for browser handling
  file_type        text NOT NULL,

  -- File size in bytes, used to display human-readable sizes in the UI
  file_size_bytes  bigint,

  -- Whether the document is visible in the library (false = draft/hidden)
  is_published     boolean NOT NULL DEFAULT true,

  -- Controls WHICH roles can access the document:
  --   'all'       — any authenticated user including cadets
  --   'personnel' — only personnel, platoon_leader, and admin
  --   'admin'     — admin only
  -- The CHECK constraint enforces only these three strings are valid.
  access_level     text NOT NULL DEFAULT 'all'
                   CHECK (access_level IN ('all', 'personnel', 'admin')),

  -- Who uploaded this document (nullable so the row survives profile deletion)
  -- ON DELETE SET NULL — if the uploader's profile is deleted, keep the document
  --   but clear the uploaded_by field instead of deleting the document too.
  uploaded_by      uuid REFERENCES public.profiles(id) ON DELETE SET NULL,

  -- Automatic audit timestamps
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- Index on 'category' because the UI filters/groups documents by category.
-- Without this index, every filter would scan the entire documents table.
CREATE INDEX IF NOT EXISTS documents_category_idx ON public.documents(category);

-- Composite index on (is_published, access_level) — the most common RLS
-- query pattern checks both columns together, so a composite index is faster
-- than two separate single-column indexes.
CREATE INDEX IF NOT EXISTS documents_published_idx ON public.documents(is_published, access_level);

-- Index on 'created_at DESC' — the document library lists newest-first,
-- so this index lets the database retrieve the sorted list without sorting.
CREATE INDEX IF NOT EXISTS documents_created_at_idx ON public.documents(created_at DESC);

-- Enable Row Level Security on the documents table.
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;

-- -- RLS POLICY: cadets_read_published_documents --
-- Controls which users can SELECT (view) documents.
-- Logic:
--   • The document must be published (is_published = true), AND
--   • Either the user is an elevated role (admin/personnel/platoon_leader)
--     who can see everything published, OR
--   • The user is a 'cadet' but the document's access_level is 'all'
--     (cadets cannot see 'personnel' or 'admin' restricted documents).
DROP POLICY IF EXISTS "cadets_read_published_documents" ON public.documents;
CREATE POLICY "cadets_read_published_documents"
  ON public.documents
  FOR SELECT
  USING (
    is_published = true
    AND (
      public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader')
      OR (
        public.current_profile_role() = 'cadet'
        AND access_level = 'all'
      )
    )
  );

-- -- RLS POLICY: personnel_read_all_documents --
-- Elevated roles (personnel, platoon_leader, admin) can read ALL documents
-- regardless of access_level or published status. This lets staff see
-- draft and restricted documents that cadets cannot.
DROP POLICY IF EXISTS "personnel_read_all_documents" ON public.documents;
CREATE POLICY "personnel_read_all_documents"
  ON public.documents
  FOR SELECT
  USING (public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader'));

-- -- RLS POLICY: personnel_insert_documents --
-- Only elevated roles can upload new documents.
-- WITH CHECK validates the data BEFORE the row is inserted.
-- Cadets cannot upload — they would be rejected here.
DROP POLICY IF EXISTS "personnel_insert_documents" ON public.documents;
CREATE POLICY "personnel_insert_documents"
  ON public.documents
  FOR INSERT
  WITH CHECK (public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader'));

-- -- RLS POLICY: personnel_update_documents --
-- Elevated roles can edit document metadata (title, category, access_level).
-- USING   — which existing rows they can target for update.
-- WITH CHECK — validates the updated data before committing.
DROP POLICY IF EXISTS "personnel_update_documents" ON public.documents;
CREATE POLICY "personnel_update_documents"
  ON public.documents
  FOR UPDATE
  USING (public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader'))
  WITH CHECK (public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader'));

-- -- RLS POLICY: admin_delete_documents --
-- Only 'admin' can permanently delete document records.
-- Separating delete from update gives admins exclusive destructive power
-- while still letting personnel manage metadata safely.
DROP POLICY IF EXISTS "admin_delete_documents" ON public.documents;
CREATE POLICY "admin_delete_documents"
  ON public.documents
  FOR DELETE
  USING (public.current_profile_role() = 'admin');

-- ============================================================
-- STORAGE BUCKET: documents
-- Supabase Storage organises files into "buckets" (similar to
-- AWS S3 buckets). Setting public = false means files are NOT
-- accessible via a public URL — a signed URL is required,
-- providing an extra layer of access control.
-- ON CONFLICT DO NOTHING makes this safe to run repeatedly.
-- ============================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('documents', 'documents', false)
ON CONFLICT (id) DO NOTHING;

-- -- STORAGE POLICY: auth_read_documents_bucket --
-- Any authenticated user (auth.uid() IS NOT NULL) can download
-- files from this bucket. The actual row-level filtering is
-- handled by the 'documents' table RLS policies above, so
-- this storage policy just ensures unauthenticated visitors
-- (e.g., web scrapers) are blocked entirely.
DROP POLICY IF EXISTS "auth_read_documents_bucket" ON storage.objects;
CREATE POLICY "auth_read_documents_bucket"
  ON storage.objects
  FOR SELECT
  USING (
    bucket_id = 'documents'
    AND auth.uid() IS NOT NULL
  );

-- -- STORAGE POLICY: personnel_upload_documents_bucket --
-- Only elevated roles can upload files to the 'documents' bucket.
-- This mirrors the INSERT policy on the 'documents' metadata table
-- so that the storage layer and the database layer stay in sync.
DROP POLICY IF EXISTS "personnel_upload_documents_bucket" ON storage.objects;
CREATE POLICY "personnel_upload_documents_bucket"
  ON storage.objects
  FOR INSERT
  WITH CHECK (
    bucket_id = 'documents'
    AND public.current_profile_role() IN ('admin', 'personnel', 'platoon_leader')
  );

-- -- STORAGE POLICY: admin_delete_documents_bucket --
-- Only 'admin' can permanently delete files from the bucket.
-- This prevents personnel from accidentally removing files that
-- other users may still need to download.
DROP POLICY IF EXISTS "admin_delete_documents_bucket" ON storage.objects;
CREATE POLICY "admin_delete_documents_bucket"
  ON storage.objects
  FOR DELETE
  USING (
    bucket_id = 'documents'
    AND public.current_profile_role() = 'admin'
  );

-- ============================================================
-- PART 4: Updated RLS Policies for 3-Tier Access Control
-- This section recreates policies across the core tables to
-- introduce the 'personnel' and 'platoon_leader' mid-tier roles.
-- Old 2-tier policies (cadet | admin) are dropped first, then
-- new 3-tier policies are created in their place.
-- ============================================================

-- Helper function: returns the role string of the currently
-- logged-in user by joining auth.uid() to the profiles table.
-- SECURITY DEFINER — runs with the function owner's privileges,
--   bypassing RLS on 'profiles' so this lookup always succeeds.
-- STABLE — tells the query planner the result won't change within
--   a single SQL statement, enabling query optimisations.
-- CREATE OR REPLACE — safe to run repeatedly (no-op if unchanged).
CREATE OR REPLACE FUNCTION public.current_profile_role()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT role FROM public.profiles WHERE user_id = auth.uid()
$$;

-- ---- profiles table ----
-- Drop the old 2-tier policy (cadet can only see self, admin sees all).
-- Replace with a 3-tier policy: self OR any elevated role can read.
-- This lets personnel/platoon_leaders look up cadet profiles.
DROP POLICY IF EXISTS "profiles_select_self_or_admin" ON public.profiles;
DROP POLICY IF EXISTS "profiles_select_self_personnel_or_admin" ON public.profiles;
CREATE POLICY "profiles_select_self_personnel_or_admin" ON public.profiles
FOR SELECT USING (
  user_id = auth.uid()                                                   -- always see own profile
  OR public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin') -- elevated roles see all
);

-- ---- cadets table ----
-- Cadets can see their own cadet record; elevated roles see all records.
-- Useful for personnel checking attendance, rank, or unit assignments.
DROP POLICY IF EXISTS "cadets_select_self_or_admin" ON public.cadets;
DROP POLICY IF EXISTS "cadets_select_self_personnel_or_admin" ON public.cadets;
CREATE POLICY "cadets_select_self_personnel_or_admin" ON public.cadets
FOR SELECT USING (
  public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')
  OR profile_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
);

-- ---- attendance_sessions table ----
-- Open sessions (is_open = true) are visible to all authenticated users,
-- including cadets who need to scan the QR code to log attendance.
-- Elevated roles can also see closed/draft sessions for management.
DROP POLICY IF EXISTS "attendance_sessions_select_public_or_admin" ON public.attendance_sessions;
DROP POLICY IF EXISTS "attendance_sessions_select_public_personnel_or_admin" ON public.attendance_sessions;
CREATE POLICY "attendance_sessions_select_public_personnel_or_admin" ON public.attendance_sessions
FOR SELECT USING (
  is_open = true                                                                  -- cadets see open sessions
  OR public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')   -- staff see all sessions
);

-- Only elevated roles can create, edit, or delete attendance sessions.
-- FOR ALL covers INSERT, UPDATE, DELETE, and SELECT in one policy.
DROP POLICY IF EXISTS "admin_manage_attendance_sessions" ON public.attendance_sessions;
DROP POLICY IF EXISTS "personnel_admin_manage_attendance_sessions" ON public.attendance_sessions;
CREATE POLICY "personnel_admin_manage_attendance_sessions" ON public.attendance_sessions
FOR ALL USING (
  public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')
)
WITH CHECK (
  public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')
);

-- ---- attendance_records table ----
-- Cadets can read their own attendance records (cadet_id matches their profile).
-- Elevated roles can read everyone's records for reporting.
DROP POLICY IF EXISTS "attendance_records_select_self_or_admin" ON public.attendance_records;
DROP POLICY IF EXISTS "attendance_records_select_self_personnel_or_admin" ON public.attendance_records;
CREATE POLICY "attendance_records_select_self_personnel_or_admin" ON public.attendance_records
FOR SELECT USING (
  public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')
  OR cadet_id IN (SELECT id FROM public.profiles WHERE user_id = auth.uid())
);

-- Elevated roles can record, correct, and manage all attendance records.
DROP POLICY IF EXISTS "admin_manage_attendance_records" ON public.attendance_records;
DROP POLICY IF EXISTS "personnel_admin_manage_attendance_records" ON public.attendance_records;
CREATE POLICY "personnel_admin_manage_attendance_records" ON public.attendance_records
FOR ALL USING (
  public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')
)
WITH CHECK (
  public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')
);

-- ---- announcements table ----
-- Published announcements are visible to all authenticated users.
-- Unpublished (draft) announcements are visible only to elevated roles
-- so they can preview before publishing.
DROP POLICY IF EXISTS "public_read_announcements" ON public.announcements;
DROP POLICY IF EXISTS "read_announcements_cadet_personnel_admin" ON public.announcements;
CREATE POLICY "read_announcements_cadet_personnel_admin" ON public.announcements
FOR SELECT USING (
  is_published = true                                                                  -- cadets see published only
  OR public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')        -- staff see drafts too
);

-- Elevated roles can create, edit, and delete announcements.
DROP POLICY IF EXISTS "admin_manage_announcements" ON public.announcements;
DROP POLICY IF EXISTS "personnel_admin_manage_announcements" ON public.announcements;
CREATE POLICY "personnel_admin_manage_announcements" ON public.announcements
FOR ALL USING (
  public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')
)
WITH CHECK (
  public.current_profile_role() IN ('personnel', 'platoon_leader', 'admin')
);

-- ============================================================
-- PART 5: Fictional Development Seed Data
-- This section inserts realistic-looking but entirely fake data
-- so that the UI renders meaningful content during development
-- and testing. It will NOT affect production data because of
-- the ON CONFLICT guards that skip or update by ID only.
-- ============================================================

-- ---- Seed: Announcements ----
-- Insert 3 sample announcements with fixed UUIDs.
-- ON CONFLICT (id) DO UPDATE — if this script is run again, the existing
-- rows are updated with the latest values instead of throwing an error.
INSERT INTO public.announcements (id, title, content, category, priority, is_published, created_at)
VALUES
  (
    'a1000000-0000-0000-0000-000000000001',
    'General Assembly & First Formation Briefing',
    'All enrolled ROTC Cadets for the current semester are directed to report at the San Enrique Campus Grandstand in complete Type B uniform on Saturday at 0700H. Bring your cadet handbook, notebook, and hydration gear.',
    'Training',        -- category used to group/filter announcements in the UI
    'important',       -- priority level: 'normal' | 'important' | 'urgent'
    true,              -- is_published = true makes this visible to all users
    now() - interval '3 days'  -- backdated so it appears in the timeline
  ),
  (
    'a1000000-0000-0000-0000-000000000002',
    'Submission of Training Documents & Medical Clearances',
    'Cadets who have pending physical examination forms and waiver documents must submit them to the ROTC Command Staff on or before next drill formation. Late submissions will affect training clearance.',
    'Administrative',
    'normal',
    true,
    now() - interval '1 day'
  ),
  (
    'a1000000-0000-0000-0000-000000000003',
    'Drill Ceremony & Parade Inspection Schedule',
    'Command drill inspection and company marching evaluation will take place this coming Sunday. Ensure proper grooming, polished boots, and complete brass insignia.',
    'Drill & Ceremony',
    'urgent',          -- 'urgent' triggers a red/high-priority badge in the UI
    true,
    now()
  )
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  content = EXCLUDED.content,
  category = EXCLUDED.category,
  priority = EXCLUDED.priority,
  is_published = EXCLUDED.is_published;

-- ---- Seed: Attendance Sessions ----
-- Insert 2 sample training sessions with distinct statuses:
--   Session 1: 'active' + is_open = true  → cadets can scan QR right now
--   Session 2: 'scheduled' + is_open = false → upcoming, not yet open
INSERT INTO public.attendance_sessions (
  id,
  title,
  session_type,
  session_date,
  start_time,
  end_time,
  location,
  status,
  is_open,
  qr_token,      -- unique token embedded in the QR code; cadets scan this to log attendance
  created_at
)
VALUES
  (
    's1000000-0000-0000-0000-000000000001',
    'Regular Training Day 1 - Orientation & Military Courtesy',
    'Regular formation',
    CURRENT_DATE,       -- session is today so it shows up as current
    '07:00:00',
    '12:00:00',
    'San Enrique Parade Grounds',
    'active',           -- status = 'active' means the session is currently in progress
    true,               -- is_open = true allows cadets to submit QR attendance
    'TOKEN-SESSION-DEV-001',   -- placeholder token (real tokens are random hex strings)
    now()
  ),
  (
    's1000000-0000-0000-0000-000000000002',
    'Regular Training Day 2 - Basic Rifle Marksmanship & Disassembly',
    'Tactical Drill',
    CURRENT_DATE + interval '7 days',   -- scheduled 1 week from now
    '07:00:00',
    '12:00:00',
    'San Enrique ROTC Training Shed',
    'scheduled',        -- status = 'scheduled' — visible to staff but not yet open
    false,              -- is_open = false prevents cadets from scanning early
    'TOKEN-SESSION-DEV-002',
    now()
  )
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  session_date = EXCLUDED.session_date,
  status = EXCLUDED.status,
  is_open = EXCLUDED.is_open;

-- ---- Seed: Documents ----
-- Insert 3 sample document metadata rows.
-- NOTE: The actual PDF files are not created by this script.
-- In development, the file_path values are placeholders; real uploads
-- happen through the Supabase Storage API in the application.
INSERT INTO public.documents (
  id,
  title,
  description,
  category,
  file_path,          -- relative path inside the 'documents' storage bucket
  file_name,          -- original filename shown to the user on download
  file_type,          -- MIME type so the browser knows how to handle the file
  file_size_bytes,    -- size in bytes (1048576 = 1 MB, 524288 = 512 KB)
  is_published,
  access_level,       -- 'all' = any authenticated user can access this document
  created_at
)
VALUES
  (
    'd1000000-0000-0000-0000-000000000001',
    'ROTC Cadet Manual & Code of Discipline',
    'Official cadet handbook containing military core values, discipline guidelines, rank structure, and training syllabus.',
    'References',
    'documents/cadet-manual-handbook.pdf',
    'ROTC_Cadet_Manual_Handbook.pdf',
    'application/pdf',
    1048576,           -- 1 MB
    true,
    'all',
    now() - interval '5 days'
  ),
  (
    'd1000000-0000-0000-0000-000000000002',
    'Official Excused Absence & Medical Waiver Form',
    'Standard form for filing official excused absences with medical certificate or academic conflict attachments.',
    'Forms',
    'documents/absence-waiver-form.pdf',
    'Excused_Absence_Waiver_Form.pdf',
    'application/pdf',
    524288,            -- 512 KB
    true,
    'all',
    now() - interval '2 days'
  ),
  (
    'd1000000-0000-0000-0000-000000000003',
    'Commandant Training Memorandum No. 01 - S.Y. 2026',
    'Official unit directive concerning formation guidelines, uniform regulations, and safety protocols.',
    'Memoranda',
    'documents/training-memo-01.pdf',
    'Commandant_Training_Memo_01.pdf',
    'application/pdf',
    786432,            -- 768 KB
    true,
    'all',
    now()
  )
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  category = EXCLUDED.category,
  is_published = EXCLUDED.is_published,
  access_level = EXCLUDED.access_level;
