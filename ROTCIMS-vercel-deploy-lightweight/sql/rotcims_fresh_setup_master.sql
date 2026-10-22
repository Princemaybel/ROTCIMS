-- ============================================================================
-- ROTCIMS MASTER DATABASE INITIALIZATION SCRIPT (FRESH SETUP)
-- San Enrique ROTC Unit — Information & Management System
--
-- HOW TO USE THIS SCRIPT:
--   1. Create a brand new project on Supabase (https://supabase.com).
--   2. In your Supabase Dashboard, go to:
--        SQL Editor -> "+ New Query"
--   3. Paste this ENTIRE file into the editor and click "RUN".
--   4. Copy your new Project URL and anon key into `js/config.js`.
--   5. In Authentication -> Providers -> Email:
--        Turn OFF "Confirm email" (recommended for offline/local campus access).
-- ============================================================================

-- ====== 1. EXTENSIONS ======
create extension if not exists "pgcrypto";

-- ====== 2. CORE TABLES ======

-- ---- Table: profiles ----
create table if not exists public.profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  first_name text not null,
  middle_name text,
  last_name text not null,
  student_id text not null unique,
  email text not null unique,
  phone text not null,
  course text not null,
  year_level text not null,
  section text not null,
  date_of_birth date not null,
  address text not null,
  profile_picture text,
  role text not null default 'cadet' check (role in ('cadet', 'personnel', 'platoon_leader', 'admin')),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  company text,
  platoon text,
  rank text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: personnel ----
create table if not exists public.personnel (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  rank text not null default '',
  position text,
  assigned_unit text,
  appointed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: cadets ----
create table if not exists public.cadets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  rotc_unit text not null default 'San Enrique ROTC Unit',
  serial_number text unique,
  enlistment_date date not null default current_date,
  company text,
  platoon text,
  rank text not null default 'Cadet Private',
  blood_type text,
  emergency_contact_name text not null,
  emergency_contact_relationship text not null,
  emergency_contact_phone text not null,
  medical_conditions text,
  qr_token text unique default encode(gen_random_bytes(16), 'hex'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: qr_codes ----
create table if not exists public.qr_codes (
  id uuid primary key default gen_random_uuid(),
  cadet_id uuid not null unique references public.cadets(id) on delete cascade,
  token text not null unique default encode(gen_random_bytes(24), 'hex'),
  is_active boolean not null default true,
  generated_at timestamptz not null default now()
);

-- ---- Table: applications ----
create table if not exists public.applications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  school_year text not null default '2025-2026',
  semester text not null default '1st Semester',
  program_type text not null default 'Basic ROTC',
  status text not null default 'pending' check (status in ('pending', 'under_review', 'approved', 'rejected')),
  reviewer_id uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  rejection_reason text,
  remarks text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: application_documents ----
create table if not exists public.application_documents (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  document_type text not null,
  file_name text not null,
  file_url text not null,
  file_size_bytes bigint,
  mime_type text,
  is_verified boolean not null default false,
  verified_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---- Table: announcements ----
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  content text not null,#
  category text not null default 'General',
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'important', 'urgent')),
  image_url text,
  is_published boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Ensure priority check allows 'important' even if table already existed
alter table public.announcements drop constraint if exists announcements_priority_check;
alter table public.announcements add constraint announcements_priority_check check (priority in ('low', 'normal', 'high', 'important', 'urgent'));

-- ---- Table: events ----
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  event_type text not null default 'drill',
  event_date date not null,
  start_time time,
  end_time time,
  location text,
  uniform_info text,
  image_url text,
  is_mandatory boolean not null default true,
  is_published boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: trainings ----
create table if not exists public.trainings (
  id uuid primary key default gen_random_uuid(),
  event_id uuid unique references public.events(id) on delete cascade,
  training_module text not null,
  instructor text,
  objectives text,
  materials text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: gallery_albums ----
create table if not exists public.gallery_albums (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  cover_image_url text,
  category text not null default 'Unit Activity',
  is_published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: gallery_images ----
create table if not exists public.gallery_images (
  id uuid primary key default gen_random_uuid(),
  album_id uuid references public.gallery_albums(id) on delete cascade,
  title text not null,
  description text,
  image_url text not null,
  category text not null default 'Unit Activity',
  is_published boolean not null default true,
  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---- Table: posts (Unified Command Posting & Social Feed) ----
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  caption text not null,
  category text not null check (category in ('gallery', 'events', 'announcements', 'requirements')),
  images jsonb not null default '[]'::jsonb,
  event_date date,
  location text,
  uniform_info text,
  album_name text,
  priority text default 'normal',
  is_published boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: attendance_sessions ----
create table if not exists public.attendance_sessions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid references public.events(id) on delete cascade,
  title text not null,
  session_type text not null default 'Regular formation',
  session_date date not null default current_date,
  qr_token text not null unique default encode(gen_random_bytes(16), 'hex'),
  is_open boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: attendance_records ----
create table if not exists public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.attendance_sessions(id) on delete cascade,
  cadet_id uuid not null references public.cadets(id) on delete cascade,
  status text not null default 'present' check (status in ('present', 'absent', 'late', 'excused')),
  scanned_at timestamptz not null default now(),
  recorded_by uuid references public.profiles(id) on delete set null,
  remarks text,
  unique (cadet_id, session_id)
);

-- ---- Table: documents ----
create table if not exists public.documents (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  category text not null default 'General',
  file_name text not null,
  file_url text not null,
  file_size_bytes bigint,
  storage_path text,
  is_published boolean not null default true,
  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- Table: id_cards ----
create table if not exists public.id_cards (
  id uuid primary key default gen_random_uuid(),
  cadet_id uuid not null unique references public.cadets(id) on delete cascade,
  card_number text not null unique,
  qr_payload text not null,
  issue_date date not null default current_date,
  expiration_date date not null default (current_date + interval '1 year')::date,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---- Table: notifications ----
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  message text not null,
  notification_type text not null default 'announcement',
  is_read boolean not null default false,
  link text,
  created_at timestamptz not null default now()
);

-- ---- Table: contact_messages ----
create table if not exists public.contact_messages (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  email text not null,
  subject text not null,
  message text not null,
  status text not null default 'unread' check (status in ('unread', 'read', 'replied')),
  created_at timestamptz not null default now()
);

-- ---- Table: audit_logs ----
create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null,
  target_table text,
  target_id uuid,
  details jsonb,
  ip_address text,
  created_at timestamptz not null default now()
);

-- ---- Table: site_settings ----
create table if not exists public.site_settings (
  key text primary key,
  value text not null,
  description text,
  updated_at timestamptz not null default now()
);

-- ====== 3. INDEXES ======
create index if not exists profiles_user_id_idx on public.profiles(user_id);
create index if not exists profiles_role_idx on public.profiles(role);
create index if not exists profiles_status_idx on public.profiles(status);
create index if not exists cadets_profile_id_idx on public.cadets(profile_id);
create index if not exists cadets_qr_token_idx on public.cadets(qr_token);
create index if not exists events_event_date_idx on public.events(event_date);
create index if not exists announcements_created_at_idx on public.announcements(created_at desc);
create index if not exists attendance_records_session_cadet_idx on public.attendance_records(session_id, cadet_id);
create index if not exists gallery_images_created_at_idx on public.gallery_images(created_at desc);

-- ====== 4. HELPER FUNCTIONS (DEFINED AFTER TABLES EXIST) ======

-- Helper to get the role of the currently logged-in user
create or replace function public.current_profile_role()
returns text as $$
  select role from public.profiles
  where user_id = auth.uid()
  limit 1;
$$ language sql security definer stable;

-- Helper to get the profile id of the currently logged-in user
create or replace function public.current_profile_id()
returns uuid as $$
  select id from public.profiles
  where user_id = auth.uid()
  limit 1;
$$ language sql security definer stable;

-- ====== 5. ROW LEVEL SECURITY (RLS) ======
alter table public.profiles enable row level security;
alter table public.personnel enable row level security;
alter table public.cadets enable row level security;
alter table public.qr_codes enable row level security;
alter table public.applications enable row level security;
alter table public.application_documents enable row level security;
alter table public.announcements enable row level security;
alter table public.events enable row level security;
alter table public.trainings enable row level security;
alter table public.gallery_albums enable row level security;
alter table public.gallery_images enable row level security;
alter table public.posts enable row level security;
alter table public.attendance_sessions enable row level security;
alter table public.attendance_records enable row level security;
alter table public.documents enable row level security;
alter table public.id_cards enable row level security;
alter table public.notifications enable row level security;
alter table public.contact_messages enable row level security;
alter table public.audit_logs enable row level security;
alter table public.site_settings enable row level security;

-- Profiles Policies
drop policy if exists "profiles_select_all" on public.profiles;
create policy "profiles_select_all" on public.profiles for select using (true);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles for insert with check (auth.uid() = user_id);

drop policy if exists "profiles_update_own_or_admin" on public.profiles;
create policy "profiles_update_own_or_admin" on public.profiles for update using (
  auth.uid() = user_id or public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "profiles_delete_admin" on public.profiles;
create policy "profiles_delete_admin" on public.profiles for delete using (
  public.current_profile_role() = 'admin'
);

-- Personnel Policies
drop policy if exists "personnel_select" on public.personnel;
create policy "personnel_select" on public.personnel for select using (true);

drop policy if exists "personnel_manage_admin" on public.personnel;
create policy "personnel_manage_admin" on public.personnel for all using (
  public.current_profile_role() = 'admin'
);

-- Cadets Policies
drop policy if exists "cadets_select" on public.cadets;
create policy "cadets_select" on public.cadets for select using (
  auth.uid() = (select user_id from public.profiles where id = profile_id)
  or public.current_profile_role() in ('admin', 'personnel', 'platoon_leader')
);

drop policy if exists "cadets_manage" on public.cadets;
create policy "cadets_manage" on public.cadets for all using (
  public.current_profile_role() in ('admin', 'personnel')
);

-- Announcements Policies
drop policy if exists "announcements_select_published" on public.announcements;
create policy "announcements_select_published" on public.announcements for select using (
  is_published = true or public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "announcements_manage" on public.announcements;
create policy "announcements_manage" on public.announcements for all using (
  public.current_profile_role() in ('admin', 'personnel')
);

-- Events Policies
drop policy if exists "events_select_published" on public.events;
create policy "events_select_published" on public.events for select using (
  is_published = true or public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "events_manage" on public.events;
create policy "events_manage" on public.events for all using (
  public.current_profile_role() in ('admin', 'personnel')
);

-- Gallery Policies
drop policy if exists "gallery_albums_select" on public.gallery_albums;
create policy "gallery_albums_select" on public.gallery_albums for select using (
  is_published = true or public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "gallery_albums_manage" on public.gallery_albums;
create policy "gallery_albums_manage" on public.gallery_albums for all using (
  public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "gallery_images_select" on public.gallery_images;
create policy "gallery_images_select" on public.gallery_images for select using (
  is_published = true or public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "gallery_images_manage" on public.gallery_images;
create policy "gallery_images_manage" on public.gallery_images for all using (
  public.current_profile_role() in ('admin', 'personnel')
);

-- Posts Policies (Posting Center)
drop policy if exists "posts_select_published" on public.posts;
create policy "posts_select_published" on public.posts for select using (
  is_published = true or public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "posts_manage_admin" on public.posts;
create policy "posts_manage_admin" on public.posts for all using (
  public.current_profile_role() in ('admin', 'personnel')
);

-- Attendance Policies
drop policy if exists "attendance_sessions_select" on public.attendance_sessions;
create policy "attendance_sessions_select" on public.attendance_sessions for select using (true);

drop policy if exists "attendance_sessions_manage" on public.attendance_sessions;
create policy "attendance_sessions_manage" on public.attendance_sessions for all using (
  public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "attendance_records_select" on public.attendance_records;
create policy "attendance_records_select" on public.attendance_records for select using (
  cadet_id in (select id from public.cadets where profile_id = public.current_profile_id())
  or public.current_profile_role() in ('admin', 'personnel', 'platoon_leader')
);

drop policy if exists "attendance_records_manage" on public.attendance_records;
create policy "attendance_records_manage" on public.attendance_records for all using (
  public.current_profile_role() in ('admin', 'personnel', 'platoon_leader')
);

-- Documents Policies
drop policy if exists "documents_select" on public.documents;
create policy "documents_select" on public.documents for select using (
  is_published = true or public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "documents_manage" on public.documents;
create policy "documents_manage" on public.documents for all using (
  public.current_profile_role() in ('admin', 'personnel')
);

-- Contact Messages Policies
drop policy if exists "contact_insert_public" on public.contact_messages;
create policy "contact_insert_public" on public.contact_messages for insert with check (true);

drop policy if exists "contact_select_admin" on public.contact_messages;
create policy "contact_select_admin" on public.contact_messages for select using (
  public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "contact_manage_admin" on public.contact_messages;
create policy "contact_manage_admin" on public.contact_messages for all using (
  public.current_profile_role() in ('admin', 'personnel')
);

-- Site Settings Policies
drop policy if exists "settings_select" on public.site_settings;
create policy "settings_select" on public.site_settings for select using (true);

drop policy if exists "settings_manage" on public.site_settings;
create policy "settings_manage" on public.site_settings for all using (
  public.current_profile_role() = 'admin'
);

-- Applications Policies
drop policy if exists "applications_select" on public.applications;
create policy "applications_select" on public.applications for select using (
  auth.uid() = (select user_id from public.profiles where id = profile_id)
  or public.current_profile_role() in ('admin', 'personnel')
);

drop policy if exists "applications_insert" on public.applications;
create policy "applications_insert" on public.applications for insert with check (
  auth.uid() = (select user_id from public.profiles where id = profile_id)
);

drop policy if exists "applications_update" on public.applications;
create policy "applications_update" on public.applications for update using (
  public.current_profile_role() in ('admin', 'personnel')
);

-- ====== 6. INITIAL SEED DATA ======
insert into public.site_settings (key, value, description) values
  ('unit_name', 'San Enrique ROTC Unit', 'Official designation of this unit'),
  ('commandant', 'Major Juan Dela Cruz (INF) PA', 'Current ROTC Commandant'),
  ('apk_download_url', 'downloads/san-enrique-rotc.apk', 'Android mobile application link'),
  ('training_day', 'Sunday', 'Regular weekly drill day')
on conflict (key) do nothing;

insert into public.gallery_albums (title, description, cover_image_url, category, is_published) values
  ('1st Instruction & Tactical Orientation', 'Official visual documentation of the opening muster, platoon alignment, and drill commands.', 'assets/gallery/1st-instruction/instruction-1.jpg', '1st Instruction', true),
  ('MS 41-42 Commencement Ceremony', 'Pass-in-review, military commission honors, and reserve enlistment.', 'assets/gallery/ms41-42-graduate/graduate-1.jpg', 'Graduation', true)
on conflict do nothing;

insert into public.announcements (title, content, category, priority, is_published) values
  ('Mandatory Haircut & Uniform Inspection on Next Assembly', 'All enrolled cadets must report in complete Type B Field Uniform with regulation standard military haircut.', 'Training', 'important', true),
  ('Release of Digital QR ID Cards for SY 2025-2026', 'Cadets can now view and download their digital QR ID card inside the cadet portal for instant drill scanning.', 'Administrative', 'normal', true)
on conflict do nothing;

insert into public.events (title, description, event_date, start_time, end_time, location, uniform_info, is_published) values
  ('Regular Formation Assembly & Haircut Inspection', 'Mandatory company alignment, hair grooming inspection, brass insignia checking, and parade drill rehearsal.', current_date + 7, '07:00:00', '12:00:00', 'San Enrique Grandstand Parade Grounds', 'Type B Field Uniform (Black Combat Boots & Combat Cap)', true),
  ('Basic Rifle Marksmanship & Mechanical Disassembly', 'Hands-on instruction in M16 service rifle disassembly, assembly, mechanical functioning, and dry-fire positioning.', current_date + 14, '07:00:00', '12:00:00', 'ROTC Armory Training Shed', 'Type B Field Uniform with White Drill Gloves', true)
on conflict do nothing;
