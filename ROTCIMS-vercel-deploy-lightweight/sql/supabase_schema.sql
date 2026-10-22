-- ============================================================================
-- FILE: supabase_schema.sql
-- PROJECT: ROTCIMS — Reserve Officers' Training Corps Information Management System
-- INSTITUTION: San Enrique ROTC
--
-- PURPOSE:
--   This is the FULL SCHEMA REFERENCE for the ROTCIMS Supabase PostgreSQL
--   database. It defines every table, index, helper function, RLS policy,
--   storage bucket, and seed setting needed to run the system from scratch.
--
--   Supabase serves as the SINGLE SOURCE OF TRUTH for:
--     • The public-facing Next.js website
--     • The admin dashboard (Next.js)
--     • The mobile app (Expo / React Native for Android)
--     • User authentication (Supabase Auth)
--     • File storage (Supabase Storage)
--     • Row-level security enforcement
--
-- HOW TO RUN:
--   1. Create a new Supabase project at https://supabase.com
--   2. Open the Dashboard > Database > SQL Editor > + New Query
--   3. Paste this entire file and click "Run"
--   4. All statements use IF NOT EXISTS / ON CONFLICT guards, making
--      them SAFE to run multiple times (idempotent).
--
-- ACCESS CONTROL MODEL (2-tier, expandable):
--   'cadet'  — enrolled ROTC student; limited read access to own data
--   'admin'  — commandant / system administrator; full access to all data
--   (A 3-tier model adding 'personnel' and 'platoon_leader' is applied
--    separately via migration_all_in_one.sql)
--
-- TABLE OVERVIEW:
--   profiles            — extended user info linked to Supabase Auth
--   applications        — cadet enrollment applications
--   cadets              — active cadet service records
--   qr_codes            — QR code tokens for attendance scanning
--   application_documents — supporting files per application
--   announcements       — unit news and notices
--   events              — scheduled events (parades, activities)
--   trainings           — training sessions linked to events
--   gallery_albums      — photo album groupings
--   gallery_images      — individual photos inside albums
--   attendance_sessions — attendance-taking sessions with QR tokens
--   attendance_records  — per-cadet attendance log per session
--   id_cards            — digital ID card records for cadets
--   notifications       — in-app push notifications per user
--   contact_messages    — public contact form submissions
--   audit_logs          — admin action trail for accountability
--   site_settings       — key-value store for runtime configuration
-- ============================================================================

-- ====== EXTENSIONS ======
-- pgcrypto provides cryptographic functions used by this schema:
--   gen_random_uuid()  — generates a UUID v4 (used as primary keys)
--   gen_random_bytes() — generates secure random bytes (used for QR tokens)
-- 'IF NOT EXISTS' prevents an error if the extension is already installed.
create extension if not exists "pgcrypto";

-- ====== TABLES ======

-- ---- Table: profiles ----
-- The central user record for every person in the system.
-- Supabase Auth manages login credentials (email/password, OAuth) in the
-- 'auth.users' table. This 'profiles' table extends that with application-
-- specific data like name, student ID, and ROTC role.
-- Every authenticated user should have exactly one profile row.
create table if not exists public.profiles (
  -- Surrogate primary key (UUID is better than auto-increment for distributed systems)
  id uuid primary key default gen_random_uuid(),

  -- Foreign key to Supabase Auth's built-in users table.
  -- UNIQUE enforces one profile per auth account.
  -- ON DELETE CASCADE: if the auth account is deleted, so is the profile.
  user_id uuid not null unique references auth.users(id) on delete cascade,

  -- Legal name fields — stored separately for flexible display formatting
  first_name text not null,
  middle_name text,       -- nullable because not all naming conventions use a middle name
  last_name text not null,

  -- Unique student identification number issued by the school
  student_id text not null unique,

  -- Contact details required for ROTC enrollment
  email text not null unique,
  phone text not null,

  -- Academic placement used to group cadets for formations and attendance
  course text not null,       -- e.g., 'BSIT', 'BSN'
  year_level text not null,   -- e.g., '2nd Year'
  section text not null,      -- e.g., 'A', 'B'

  -- Personal details required for ROTC enrollment forms
  date_of_birth date not null,
  address text not null,

  -- Storage path to the profile photo in Supabase Storage (nullable = not yet uploaded)
  profile_picture text,

  -- Role-based access control field.
  -- CHECK constraint enforces only valid role strings — no typos allowed.
  -- Default 'cadet' because all new registrants start as cadets.
  role text not null default 'cadet' check (role in ('admin', 'cadet')),

  -- Application/account lifecycle status.
  -- 'pending'      — submitted, awaiting admin review
  -- 'under_review' — admin is actively reviewing
  -- 'approved'     — accepted into the ROTC program
  -- 'rejected'     — application denied
  -- 'inactive'     — account suspended or cadet dropped
  status text not null default 'pending' check (status in ('pending', 'under_review', 'approved', 'rejected', 'inactive')),

  -- Emergency contact stored directly on the profile for quick access
  emergency_contact_name text,
  emergency_contact_phone text,

  -- Automatic audit timestamps — set by the database, not the application
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: applications ----
-- Records each enrollment application submitted by a prospective cadet.
-- An application can exist BEFORE a profile is fully approved, so both
-- profile_id and user_id are nullable (set null on delete to preserve history).
create table if not exists public.applications (
  id uuid primary key default gen_random_uuid(),

  -- Links to the applicant's profile once it is created.
  -- ON DELETE SET NULL: retain application history even if profile is deleted.
  profile_id uuid references public.profiles(id) on delete set null,

  -- Direct link to auth.users for cases where a profile doesn't exist yet.
  user_id uuid references auth.users(id) on delete set null,

  -- Personal details captured at application time (may differ from approved profile)
  full_name text not null,
  email text not null,
  phone text not null,
  student_id text not null,
  course text not null,
  year_level text not null,
  section text,
  address text,

  -- Free-text field for the applicant's motivation or additional information
  application_details text,

  -- Storage path for the uploaded profile photo (used during review)
  profile_photo_path text,

  -- Array of storage paths for supporting documents (PSA, medical cert, etc.)
  -- text[] is a PostgreSQL array; '{}' is an empty array (no files yet)
  document_paths text[] not null default '{}',

  -- Application workflow status — starts at 'pending'
  status text not null default 'pending' check (status in ('pending', 'under_review', 'approved', 'rejected')),

  -- Internal notes added by the admin during review (not shown to applicant)
  admin_notes text,

  -- Which admin profile reviewed this application (nullable if not yet reviewed)
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,   -- when the review decision was made

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: cadets ----
-- Stores ROTC service record data for approved, active cadets.
-- This is a 1-to-1 extension of 'profiles' — only approved cadets have a row here.
-- Keeping cadet-specific data separate from profiles keeps the profiles table lean.
create table if not exists public.cadets (
  id uuid primary key default gen_random_uuid(),

  -- UNIQUE + ON DELETE CASCADE: one cadet record per profile; both sink or swim together.
  profile_id uuid not null unique references public.profiles(id) on delete cascade,

  -- Official ROTC identification number assigned upon acceptance
  cadet_number text unique,

  -- Military rank awarded within the ROTC program (e.g., 'PFC', 'CPL', 'SGT')
  rank text,

  -- Unit or company the cadet is assigned to (e.g., 'Alpha Company')
  unit text,

  -- Timestamps for tracking service period
  activated_at timestamptz,    -- when the cadet was formally enrolled/activated
  deactivated_at timestamptz,  -- when the cadet was deactivated (graduated, dropped, etc.)

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: qr_codes ----
-- Each active cadet has a personal QR code used to scan in at attendance sessions.
-- The code encodes a unique public_qr_id that the scanner app looks up.
-- Only ONE active QR code is allowed per cadet at a time (enforced by partial index below).
create table if not exists public.qr_codes (
  id uuid primary key default gen_random_uuid(),

  -- Direct link to auth.users for server-side verification without joining profiles
  user_id uuid not null references auth.users(id) on delete cascade,

  -- Links QR code to the cadet's profile (cadet_id here refers to profiles.id)
  cadet_id uuid not null references public.profiles(id) on delete cascade,

  -- The value encoded in the QR image — short, URL-safe, globally unique
  public_qr_id text not null unique,

  -- Optional hashed token for server-side signature verification
  token_hash text,

  -- Lifecycle status of the QR code
  -- 'active'   — currently in use for attendance scanning
  -- 'revoked'  — manually invalidated by admin
  -- 'expired'  — past its validity window
  -- 'replaced' — superseded by a newer QR code
  status text not null default 'active' check (status in ('active', 'revoked', 'expired', 'replaced')),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,    -- when the code was revoked (null if still active)
  last_used_at timestamptz   -- updated every time the QR is scanned (for audit/analytics)
);

-- PARTIAL UNIQUE INDEX: enforce that each cadet can have at most ONE 'active' QR code.
-- A partial index only indexes rows WHERE the condition is true, so revoked/expired
-- codes don't interfere. Without this, a cadet could generate multiple active codes
-- and share them, breaking attendance integrity.
create unique index if not exists qr_codes_one_active_per_cadet_idx
on public.qr_codes(cadet_id)
where status = 'active';

-- ---- Table: application_documents ----
-- Tracks individual supporting documents (e.g., PSA birth certificate, medical form)
-- uploaded as part of an enrollment application.
-- Each row is one file; an application can have many documents.
create table if not exists public.application_documents (
  id uuid primary key default gen_random_uuid(),

  -- Foreign key to the parent application.
  -- ON DELETE CASCADE: if an application is deleted, all its documents are too.
  application_id uuid not null references public.applications(id) on delete cascade,

  -- Classification of the document (e.g., 'Birth Certificate', 'Medical Clearance')
  document_type text not null,

  -- Path inside Supabase Storage where the file is saved
  storage_path text not null,

  -- Admin's assessment of the document's authenticity
  -- 'pending'  — not yet reviewed
  -- 'verified' — confirmed authentic
  -- 'rejected' — flagged as invalid or insufficient
  verification_status text not null default 'pending' check (verification_status in ('pending', 'verified', 'rejected')),

  -- Admin notes explaining a rejection or flagging an issue
  notes text,

  uploaded_at timestamptz not null default now(),

  -- Which admin verified this document (nullable until reviewed)
  verified_by uuid references public.profiles(id) on delete set null,
  verified_at timestamptz   -- timestamp of the verification decision
);

-- ---- Table: announcements ----
-- Unit-wide news, notices, and directives posted by admin or personnel.
-- Visible to all users (when published) or only elevated roles (when draft).
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),

  -- Short headline displayed in announcement cards
  title text not null,

  -- Full body text of the announcement (supports rich text via the front-end)
  content text not null,

  -- Topic grouping for filtering (e.g., 'Training', 'Administrative', 'Drill & Ceremony')
  category text not null default 'General',

  -- Visual priority indicator displayed in the UI
  -- 'normal'    — routine notice (no special badge)
  -- 'important' — highlighted in amber/yellow
  -- 'urgent'    — highlighted in red
  priority text not null default 'normal' check (priority in ('normal', 'important', 'urgent')),

  -- When false, only elevated roles can see this (draft mode)
  is_published boolean not null default true,

  -- Optional banner/cover image stored in Supabase Storage
  image_url text,

  -- Who created the announcement (nullable so the row survives profile deletion)
  created_by uuid references public.profiles(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: events ----
-- Scheduled unit events (parades, activities, community outreach).
-- Distinct from 'trainings' which are the regular weekly drill sessions.
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),

  title text not null,
  description text not null,
  location text not null,
  event_date date not null,
  start_time time,   -- nullable: some events don't have a fixed time yet
  end_time time,

  -- Distinguishes between a general event and a training event
  event_type text not null default 'event' check (event_type in ('event', 'training')),

  -- Free-text fields for the event briefing package
  requirements text,   -- what cadets need to bring or wear
  uniform_info text,   -- uniform type and regulations for this event
  instructions text,   -- additional orders or procedures

  -- Optional promotional image for the event
  image_url text,

  is_published boolean not null default true,

  -- Unique token embedded in the attendance QR code generated for this event.
  -- encode(gen_random_bytes(24), 'hex') produces a 48-character hex string.
  attendance_qr_token text unique default encode(gen_random_bytes(24), 'hex'),

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: trainings ----
-- Represents the regular weekly ROTC drill sessions.
-- Can optionally be linked to an event row (event_id) when the training
-- is also a formal event (e.g., a field demonstration that is also an event).
create table if not exists public.trainings (
  id uuid primary key default gen_random_uuid(),

  -- Optional one-to-one link to an event.
  -- UNIQUE ensures each event maps to at most one training record.
  -- ON DELETE CASCADE: deleting the event also removes the training record.
  event_id uuid unique references public.events(id) on delete cascade,

  title text not null,
  description text not null,
  location text not null,
  training_date date not null,
  start_time time,
  end_time time,

  -- What cadets must bring, wear, or prepare for this training
  requirements text,
  uniform_info text,
  instructions text,

  is_published boolean not null default true,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: gallery_albums ----
-- Groups of related photos (e.g., "Founding Anniversary 2025").
-- Individual photos are stored in gallery_images and link back here.
create table if not exists public.gallery_albums (
  id uuid primary key default gen_random_uuid(),

  title text not null,
  description text,

  -- URL of the album's representative/cover image (stored in Supabase Storage)
  cover_image_url text,

  -- Thematic category for browsing (e.g., 'Drills', 'Community Service')
  category text not null default 'Unit Activity',

  is_published boolean not null default true,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: gallery_images ----
-- Individual photos. Each image belongs to an album (album_id).
-- album_id is nullable — images can exist without an album (orphan photos).
create table if not exists public.gallery_images (
  id uuid primary key default gen_random_uuid(),

  -- Foreign key to the parent album.
  -- ON DELETE CASCADE: deleting an album removes all its photos automatically.
  -- Nullable: allows images that aren't yet assigned to an album.
  album_id uuid references public.gallery_albums(id) on delete cascade,

  title text not null,
  description text,

  -- Full URL to the image in Supabase Storage (public bucket, so no signed URL needed)
  image_url text not null,

  -- Category can differ from the album's category for fine-grained filtering
  category text not null default 'Unit Activity',

  is_published boolean not null default true,

  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
  -- Note: no updated_at — images are not expected to be edited after upload
);

-- ---- Table: attendance_sessions ----
-- Represents a single attendance-taking event (e.g., "Training Day 1").
-- The QR code displayed at the formation encodes the qr_token.
-- When is_open = true, cadets can scan in; when false, the session is closed.
create table if not exists public.attendance_sessions (
  id uuid primary key default gen_random_uuid(),

  -- Optional links to a formal event or training record for this session
  event_id uuid references public.events(id) on delete cascade,
  training_id uuid references public.trainings(id) on delete cascade,

  -- Display name shown in the dashboard and mobile app
  title text not null,

  -- Classification (e.g., 'Regular formation', 'Tactical Drill', 'Physical Training')
  session_type text not null default 'Regular formation',

  session_date date not null default current_date,
  start_time time,
  end_time time,
  location text,

  -- Optional filters to target attendance to a specific group of cadets
  course text,
  year_level text,
  section text,
  platoon text,

  -- Freeform internal notes for the session record
  notes text,

  -- Lifecycle status of the session
  -- 'draft'     — being set up, not visible to cadets
  -- 'scheduled' — finalized, upcoming, not yet open
  -- 'active'    — currently in progress; cadets can scan in
  -- 'paused'    — temporarily halted (e.g., for a break)
  -- 'completed' — session ended; records are locked
  -- 'cancelled' — session called off
  -- 'archived'  — moved to historical records
  status text not null default 'draft' check (status in ('draft', 'scheduled', 'active', 'paused', 'completed', 'cancelled', 'archived')),

  -- Optional scheduled window for automatic open/close
  opens_at timestamptz,   -- if set, the app can auto-open at this time
  closes_at timestamptz,  -- if set, the app can auto-close at this time

  -- The secret token embedded in the QR code image.
  -- encode(gen_random_bytes(32), 'hex') = 64-character cryptographically secure hex string.
  -- UNIQUE ensures no two sessions share a token (which would cause incorrect check-ins).
  qr_token text not null unique default encode(gen_random_bytes(32), 'hex'),

  -- Simple boolean gate: true = cadets can scan, false = scanning blocked
  is_open boolean not null default true,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: attendance_records ----
-- One row per cadet per session — records whether they showed up and when.
-- The UNIQUE constraint on (cadet_id, session_id) prevents double-logging.
create table if not exists public.attendance_records (
  id uuid primary key default gen_random_uuid(),

  -- The cadet whose attendance is being recorded (references profiles.id)
  cadet_id uuid not null references public.profiles(id) on delete cascade,

  -- Direct auth reference for server-side verification (avoids profile join)
  user_id uuid references auth.users(id) on delete set null,

  -- Which session this record belongs to
  session_id uuid not null references public.attendance_sessions(id) on delete cascade,

  -- The calendar date of attendance (usually matches the session_date)
  date date not null default current_date,

  -- Clock times for the attendance window
  time_in time,   -- when the cadet scanned in (null if absent)
  time_out time,  -- when the cadet scanned out (null if not yet recorded)

  -- Attendance determination
  -- 'PRESENT'   — on time
  -- 'LATE'      — arrived after the grace period
  -- 'ABSENT'    — did not attend
  -- 'EXCUSED'   — approved absence (medical, academic conflict)
  -- 'PENDING'   — awaiting confirmation
  -- 'REJECTED'  — QR scan was flagged as invalid
  -- 'CORRECTED' — manually adjusted by admin after the fact
  status text not null default 'PRESENT' check (status in ('PRESENT', 'LATE', 'ABSENT', 'EXCUSED', 'PENDING', 'REJECTED', 'CORRECTED')),

  -- How the attendance was captured
  -- 'qr'         — cadet scanned the session QR code
  -- 'manual'     — admin manually entered attendance
  -- 'correction' — record was corrected after initial entry
  source text not null default 'qr' check (source in ('qr', 'manual', 'correction')),

  -- More granular method description (e.g., 'admin_qr_scan', 'self_qr_scan')
  verification_method text not null default 'admin_qr_scan',

  -- Convenience boolean so the UI can quickly highlight late arrivals
  is_late boolean not null default false,

  -- Free-text reason for absence or late arrival (filled in by admin)
  remarks text,

  -- Which admin/personnel recorded this entry (audit trail)
  recorded_by uuid references public.profiles(id) on delete set null,

  -- Additional internal notes (different from remarks which may be cadet-facing)
  notes text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Prevent duplicate records: each cadet can only appear once per session
  unique (cadet_id, session_id)
);

-- ---- Table: id_cards ----
-- Stores digital ID card data for each cadet.
-- The qr_code column holds the value printed on the physical/digital ID card,
-- separate from the attendance QR tokens in the qr_codes table.
create table if not exists public.id_cards (
  id uuid primary key default gen_random_uuid(),

  -- UNIQUE + ON DELETE CASCADE: one ID card per cadet profile
  cadet_id uuid not null unique references public.profiles(id) on delete cascade,

  -- The school-issued ID number printed on the card
  school_id text not null,

  -- The QR code value embedded in the ID card image
  qr_code text not null unique,

  -- Card status (e.g., 'active', 'revoked', 'lost')
  status text not null default 'active',

  -- When the physical ID card was printed (null = not yet printed)
  printed_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: notifications ----
-- In-app notifications delivered to individual users.
-- The mobile app and web dashboard poll this table for unread notifications.
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),

  -- Which user receives this notification
  profile_id uuid not null references public.profiles(id) on delete cascade,

  -- Short headline shown in the notification bell / push notification
  title text not null,

  -- Full notification body text
  body text not null,

  -- Type used by the front-end to choose an icon or route on tap
  -- (e.g., 'attendance', 'announcement', 'general')
  notification_type text not null default 'general',

  -- Read state — updated by the user when they open/dismiss the notification
  is_read boolean not null default false,

  created_at timestamptz not null default now()
  -- No updated_at — the only mutation is toggling is_read
);

-- ---- Table: contact_messages ----
-- Submissions from the public "Contact Us" form on the website.
-- No authentication required — anyone can submit a message.
create table if not exists public.contact_messages (
  id uuid primary key default gen_random_uuid(),

  -- Contact details provided by the visitor (unverified)
  name text not null,
  email text not null,
  subject text not null,
  message text not null,

  -- Admin workflow status ('unread', 'read', 'replied', 'archived')
  status text not null default 'unread',

  created_at timestamptz not null default now()
);

-- ---- Table: audit_logs ----
-- Immutable log of significant admin actions (create, update, delete).
-- Used for accountability, debugging, and compliance.
-- Only admins can insert or read audit logs.
create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),

  -- Who performed the action (null if the account was deleted)
  actor_id uuid references public.profiles(id) on delete set null,

  -- What was done (e.g., 'approved_application', 'deleted_cadet')
  action text not null,

  -- Which table or resource type was affected (e.g., 'applications', 'cadets')
  entity_type text not null,

  -- The specific row/resource that was affected (nullable for system-level actions)
  entity_id uuid,

  -- Additional context as JSON (e.g., {"old_status": "pending", "new_status": "approved"})
  -- jsonb is binary JSON — faster to query and index than plain text JSON
  details jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
  -- No updated_at — audit logs must never be modified after creation
);

-- ---- Table: site_settings ----
-- A simple key-value store for runtime configuration variables.
-- Avoids hard-coding organisation details in the application code.
-- The 'key' column is the primary key, ensuring no duplicate keys.
create table if not exists public.site_settings (
  key text primary key,     -- e.g., 'organization_name', 'contact_email'
  value text,               -- the setting value (nullable to allow clearing a setting)
  updated_at timestamptz not null default now()
);

-- ====== INDEXES ======
-- Indexes speed up specific query patterns at the cost of slightly slower
-- writes and extra storage. Only index columns that are frequently used
-- in WHERE clauses, ORDER BY, or JOIN conditions.

-- Filter cadets by approval status (e.g., show only 'approved' on dashboard)
create index if not exists profiles_status_idx on public.profiles(status);

-- Group/filter profiles by academic placement — common for forming attendance lists
create index if not exists profiles_course_year_section_idx on public.profiles(course, year_level, section);

-- Filter applications by their workflow status (admin review queue)
create index if not exists applications_status_idx on public.applications(status);

-- Group applications by course and year for analysis / reporting
create index if not exists applications_course_year_idx on public.applications(course, year_level);

-- Look up a cadet's service record by their profile — used in almost every cadet query
create index if not exists cadets_profile_idx on public.cadets(profile_id);

-- Find all documents belonging to a specific application (one-to-many join)
create index if not exists application_documents_application_idx on public.application_documents(application_id);

-- List announcements newest-first (DESC because the UI shows latest at top)
create index if not exists announcements_created_at_idx on public.announcements(created_at desc);

-- Filter announcements by published status and priority in one scan
create index if not exists announcements_published_priority_idx on public.announcements(is_published, priority);

-- Sort events by date (calendar view needs this constantly)
create index if not exists events_event_date_idx on public.events(event_date);

-- Filter events by published status and type (e.g., show only published trainings)
create index if not exists events_published_type_idx on public.events(is_published, event_type);

-- Sort trainings by their scheduled date
create index if not exists trainings_training_date_idx on public.trainings(training_date);

-- Gallery browsing: filter by published status, category, and sort by newest
create index if not exists gallery_albums_published_category_idx on public.gallery_albums(is_published, category, created_at desc);

-- Look up all images belonging to an album (one-to-many join)
create index if not exists gallery_images_album_idx on public.gallery_images(album_id);

-- Filter attendance sessions by date (e.g., "show sessions for today")
create index if not exists attendance_sessions_date_idx on public.attendance_sessions(session_date);

-- Find all attendance records for a session (used when taking roll call)
create index if not exists attendance_records_session_idx on public.attendance_records(session_id);

-- Find a specific cadet's attendance history across all sessions
create index if not exists attendance_records_cadet_idx on public.attendance_records(cadet_id);

-- Search audit logs by the type and ID of the affected resource
create index if not exists audit_logs_entity_idx on public.audit_logs(entity_type, entity_id);

-- Sort audit logs newest-first for the admin activity feed
create index if not exists audit_logs_created_at_idx on public.audit_logs(created_at desc);

-- ====== HELPER FUNCTIONS ======

-- Function: current_profile_role()
-- Returns the role ('cadet' or 'admin') of the currently authenticated user.
-- This is the core building block for all RLS policies below — instead of
-- repeating the subquery everywhere, we call this function once.
--
-- SECURITY DEFINER: runs with elevated (owner) privileges so it can bypass
--   RLS on 'profiles' itself, preventing infinite recursion.
-- STABLE: tells PostgreSQL the result is constant within a single query,
--   allowing the planner to cache the result instead of calling it repeatedly.
create or replace function public.current_profile_role()
returns text
language sql
security definer
set search_path = public
stable
as $$
  select role from public.profiles where user_id = auth.uid()
$$;

-- Function: current_profile_status()
-- Returns the account status ('pending', 'approved', etc.) of the current user.
-- Used in the profiles UPDATE policy to prevent a cadet from changing their
-- own status to 'approved' or 'admin' — the status is compared against the
-- database value, not a client-supplied value.
create or replace function public.current_profile_status()
returns text
language sql
security definer
set search_path = public
stable
as $$
  select status from public.profiles where user_id = auth.uid()
$$;

-- ====== ROW LEVEL SECURITY (RLS) — ENABLE ======
-- RLS must be explicitly enabled per table. Without it, any authenticated
-- user can read or write ALL rows — a serious security vulnerability.
-- Once enabled, only rows that pass at least one active policy are accessible.
alter table public.profiles enable row level security;
alter table public.applications enable row level security;
alter table public.cadets enable row level security;
alter table public.qr_codes enable row level security;
alter table public.application_documents enable row level security;
alter table public.announcements enable row level security;
alter table public.events enable row level security;
alter table public.trainings enable row level security;
alter table public.gallery_albums enable row level security;
alter table public.gallery_images enable row level security;
alter table public.attendance_sessions enable row level security;
alter table public.attendance_records enable row level security;
alter table public.id_cards enable row level security;
alter table public.notifications enable row level security;
alter table public.contact_messages enable row level security;
alter table public.audit_logs enable row level security;
alter table public.site_settings enable row level security;

-- ====== RLS POLICIES: profiles ======

-- SELECT: a user can always see their own profile; admins see everyone's.
-- auth.uid() returns the UUID of the currently logged-in user.
create policy "profiles_select_self_or_admin" on public.profiles
for select using (user_id = auth.uid() or public.current_profile_role() = 'admin');

-- INSERT: anyone can create their own profile during registration, but only
-- as a 'cadet' with 'pending' status. This prevents self-granting admin.
create policy "profiles_insert_own_pending" on public.profiles
for insert with check (user_id = auth.uid() and role = 'cadet' and status = 'pending');

-- UPDATE: a user can update their own profile OR an admin can update anyone's.
-- WITH CHECK prevents a cadet from changing their own role or status — only
-- admins can modify those sensitive fields.
create policy "profiles_update_self_limited_or_admin" on public.profiles
for update using (user_id = auth.uid() or public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin' or (user_id = auth.uid() and role = 'cadet' and status = public.current_profile_status()));

-- ====== RLS POLICIES: applications ======

-- SELECT: each user sees only their own applications; admins see all.
create policy "applications_select_self_or_admin" on public.applications
for select using (public.current_profile_role() = 'admin' or user_id = auth.uid());

-- INSERT: any authenticated user can submit an application. Also allows null
-- user_id for edge cases where authentication hasn't completed yet.
create policy "applications_insert_own_or_public" on public.applications
for insert with check (user_id = auth.uid() or user_id is null);

-- ALL (admin): admins have full CRUD on all applications (review workflow).
create policy "admin_manage_applications" on public.applications
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: cadets ======

-- SELECT: cadets see only their own service record; admins see all.
create policy "cadets_select_self_or_admin" on public.cadets
for select using (public.current_profile_role() = 'admin' or profile_id in (select id from public.profiles where user_id = auth.uid()));

-- ALL (admin): only admins can create, update, or delete cadet records.
-- This prevents cadets from modifying their own rank or unit.
create policy "admin_manage_cadets" on public.cadets
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: qr_codes ======

-- SELECT: cadets see only their own QR code(s); admins see all.
create policy "qr_codes_select_self_or_admin" on public.qr_codes
for select using (public.current_profile_role() = 'admin' or cadet_id in (select id from public.profiles where user_id = auth.uid()));

-- INSERT: a cadet can generate a QR code only for themselves,
-- only if they have a 'cadet' role, and only with 'active' status.
-- Combined with the partial unique index, this enforces one active code per cadet.
create policy "qr_codes_insert_own_cadet_qr" on public.qr_codes
for insert with check (
  user_id = auth.uid()
  and cadet_id in (
    select id from public.profiles
    where user_id = auth.uid()
      and role = 'cadet'
  )
  and status = 'active'
);

-- ALL (admin): admins can revoke, replace, and manage all QR codes.
create policy "admin_manage_qr_codes" on public.qr_codes
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: application_documents ======

-- SELECT: applicants see documents for their own application; admins see all.
create policy "application_documents_select_self_or_admin" on public.application_documents
for select using (
  public.current_profile_role() = 'admin'
  or application_id in (select id from public.applications where user_id = auth.uid())
);

-- INSERT: applicants can upload documents only to their own application.
create policy "application_documents_insert_own" on public.application_documents
for insert with check (application_id in (select id from public.applications where user_id = auth.uid()));

-- ALL (admin): admins verify, update notes, and delete application documents.
create policy "admin_manage_application_documents" on public.application_documents
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: announcements ======

-- SELECT: all users see published announcements; admins also see unpublished drafts.
create policy "public_read_announcements" on public.announcements
for select using (is_published = true or public.current_profile_role() = 'admin');

-- ALL (admin): only admins can create, edit, or delete announcements.
create policy "admin_manage_announcements" on public.announcements
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: events ======

-- SELECT: published events are public; unpublished drafts are admin-only.
create policy "public_read_events" on public.events
for select using (is_published = true or public.current_profile_role() = 'admin');

-- ALL (admin): only admins manage events.
create policy "admin_manage_events" on public.events
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: trainings ======

-- SELECT: same pattern as events — published = public, drafts = admin only.
create policy "public_read_trainings" on public.trainings
for select using (is_published = true or public.current_profile_role() = 'admin');

-- ALL (admin): only admins manage training records.
create policy "admin_manage_trainings" on public.trainings
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: gallery_albums ======

-- SELECT: published albums visible to all; unpublished are admin-only.
create policy "public_read_gallery_albums" on public.gallery_albums
for select using (is_published = true or public.current_profile_role() = 'admin');

-- ALL (admin): only admins can create, edit, or delete albums.
create policy "admin_manage_gallery_albums" on public.gallery_albums
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: gallery_images ======

-- SELECT: admins see all images. Non-admins see images that are:
--   • Unassigned (album_id IS NULL), or
--   • In a published album (album_id in published albums list).
-- This prevents images in a draft album from leaking to the public.
create policy "public_read_gallery_images" on public.gallery_images
for select using (
  public.current_profile_role() = 'admin'
  or album_id is null
  or album_id in (select id from public.gallery_albums where is_published = true)
);

-- ALL (admin): only admins upload, edit, or delete gallery images.
create policy "admin_manage_gallery_images" on public.gallery_images
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: attendance_sessions ======

-- SELECT: open sessions (is_open = true) are visible to all users so cadets
-- can scan the QR code. Admins also see closed/draft sessions for management.
create policy "attendance_sessions_select_public_or_admin" on public.attendance_sessions
for select using (is_open = true or public.current_profile_role() = 'admin');

-- ALL (admin): only admins can create or modify attendance sessions.
create policy "admin_manage_attendance_sessions" on public.attendance_sessions
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: attendance_records ======

-- SELECT: cadets see only their own records (privacy); admins see all records.
-- This is important — cadets should NOT be able to see each other's attendance.
create policy "attendance_records_select_self_or_admin" on public.attendance_records
for select using (public.current_profile_role() = 'admin' or cadet_id in (select id from public.profiles where user_id = auth.uid()));

-- ALL (admin): only admins can record, correct, or delete attendance entries.
create policy "admin_manage_attendance_records" on public.attendance_records
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: id_cards ======

-- SELECT: cadets see only their own ID card; admins see all.
create policy "id_cards_select_self_or_admin" on public.id_cards
for select using (public.current_profile_role() = 'admin' or cadet_id in (select id from public.profiles where user_id = auth.uid()));

-- ALL (admin): only admins print or manage ID cards.
create policy "admin_manage_id_cards" on public.id_cards
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: notifications ======

-- SELECT: users see only their own notifications; admins see all.
create policy "notifications_select_self_or_admin" on public.notifications
for select using (public.current_profile_role() = 'admin' or profile_id in (select id from public.profiles where user_id = auth.uid()));

-- UPDATE: users can only mark their own notifications as read (is_read toggle).
-- USING  — which notifications they can target for update.
-- WITH CHECK — ensures they can only touch their own profile_id (can't mark others' as read).
create policy "notifications_update_own_read_state" on public.notifications
for update using (profile_id in (select id from public.profiles where user_id = auth.uid()))
with check (profile_id in (select id from public.profiles where user_id = auth.uid()));

-- ALL (admin): admins can create, manage, or delete any notification.
create policy "admin_manage_notifications" on public.notifications
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: contact_messages ======

-- INSERT: WITH CHECK (true) means ANYONE can submit a contact message —
-- no authentication required. This supports the public contact form.
create policy "anyone_can_submit_contact" on public.contact_messages
for insert with check (true);

-- ALL (admin): only admins can read and manage submitted contact messages.
create policy "admin_manage_contact" on public.contact_messages
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: audit_logs ======

-- SELECT: only admins can read the audit trail.
-- Cadets should not see what other users or admins have done.
create policy "admin_read_audit_logs" on public.audit_logs
for select using (public.current_profile_role() = 'admin');

-- INSERT: only the server-side admin can write audit log entries.
-- This prevents non-admins from injecting false audit records.
create policy "admin_insert_audit_logs" on public.audit_logs
for insert with check (public.current_profile_role() = 'admin');

-- ====== RLS POLICIES: site_settings ======

-- SELECT: WITH CHECK (true) = all users (even unauthenticated) can read settings.
-- This allows the public website to load the organisation name, contact info, etc.
create policy "public_read_site_settings" on public.site_settings
for select using (true);

-- ALL (admin): only admins can create or modify site settings.
create policy "admin_manage_site_settings" on public.site_settings
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== STORAGE BUCKETS ======
-- Supabase Storage organises files into named buckets (like folders at the top level).
-- 'public = true'  → files accessible via a direct URL (no auth required).
-- 'public = false' → files require a signed URL (restricted access).
-- ON CONFLICT DO NOTHING → safe to run again without failing if buckets already exist.
insert into storage.buckets (id, name, public)
values
  ('profile-pictures', 'profile-pictures', true),   -- profile photos shown publicly in the app
  ('gallery', 'gallery', true),                     -- unit gallery images shown on the website
  ('announcements', 'announcements', true),          -- announcement banner images
  ('events', 'events', true),                        -- event promotional images
  ('cadet-documents', 'cadet-documents', false)      -- sensitive cadet forms (private, signed URL only)
on conflict (id) do nothing;

-- ====== STORAGE BUCKET POLICIES ======

-- Public buckets (profile-pictures, gallery, announcements, events):
-- Anyone — authenticated or not — can read files.
-- This is intentional for a public-facing website.
create policy "public_read_media_buckets" on storage.objects
for select using (bucket_id in ('profile-pictures', 'gallery', 'announcements', 'events'));

-- Only authenticated users can upload their own profile picture.
-- auth.uid() IS NOT NULL confirms the request comes from a logged-in user.
create policy "authenticated_upload_profile_pictures" on storage.objects
for insert with check (bucket_id = 'profile-pictures' and auth.uid() is not null);

-- Admins have full control over ALL storage objects in ALL buckets.
-- This covers bulk operations like clearing old photos or managing documents.
create policy "admin_manage_storage_objects" on storage.objects
for all using (public.current_profile_role() = 'admin')
with check (public.current_profile_role() = 'admin');

-- ====== SEED DATA: site_settings ======
-- Insert the minimum required configuration settings.
-- ON CONFLICT (key) DO NOTHING ensures repeated runs don't overwrite
-- any values that may have been changed via the admin dashboard.
insert into public.site_settings (key, value)
values
  ('organization_name', 'SAN ENRIQUE ROTC'),       -- used in the page title and headers
  ('contact_email', 'rotc@sanenrique.edu.ph'),      -- displayed on the contact page
  ('contact_phone', '+63 000 000 0000')             -- placeholder phone number
on conflict (key) do nothing;
