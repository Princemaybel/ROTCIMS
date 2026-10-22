-- ==========================================================================
-- FIX: Add missing created_at and updated_at columns to attendance_records
-- ==========================================================================
-- Run this in your Supabase Dashboard -> SQL Editor (project cntisxkugmvwsommzjom)

ALTER TABLE public.attendance_records 
ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW();

ALTER TABLE public.attendance_records 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Set existing rows to have created_at match scanned_at if scanned_at exists
UPDATE public.attendance_records 
SET created_at = scanned_at 
WHERE created_at IS NULL AND scanned_at IS NOT NULL;
