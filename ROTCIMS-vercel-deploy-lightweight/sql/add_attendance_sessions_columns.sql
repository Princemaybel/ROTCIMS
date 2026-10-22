-- ============================================================================
-- FILE: add_attendance_sessions_columns.sql
-- PURPOSE: Adds missing columns to public.attendance_sessions:
--          - start_time (time)
--          - end_time (time)
--          - location (text)
--          - status (text)
--
-- HOW TO RUN:
--   1. Open Supabase Dashboard: https://supabase.com/dashboard
--   2. Click "SQL Editor" -> "+ New Query"
--   3. Paste this script and click "RUN"
-- ============================================================================

ALTER TABLE public.attendance_sessions
  ADD COLUMN IF NOT EXISTS start_time time,
  ADD COLUMN IF NOT EXISTS end_time time,
  ADD COLUMN IF NOT EXISTS location text,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'active';

-- Notify schema cache reload
NOTIFY pgrst, 'reload schema';

