-- ============================================================
-- FIX: attendance_records FK violation + missing cadets rows
-- 
-- Run this in Supabase SQL Editor if you get:
--   "violates foreign key constraint attendance_records_cadet_id_fkey"
--
-- ROOT CAUSE:
--   attendance_records.cadet_id → cadets.id  (NOT profiles.id)
--   Some approved cadet profiles may not have a matching row in
--   the cadets table. This script auto-creates the missing rows.
-- ============================================================

-- STEP 1: Create cadets rows for all approved cadet profiles
-- that don't already have one. Uses a safe INSERT ... WHERE NOT EXISTS.
INSERT INTO public.cadets (
  profile_id,
  rotc_unit,
  enlistment_date,
  company,
  platoon,
  rank,
  emergency_contact_name,
  emergency_contact_relationship,
  emergency_contact_phone
)
SELECT
  p.id            AS profile_id,
  'San Enrique ROTC Unit' AS rotc_unit,
  CURRENT_DATE    AS enlistment_date,
  COALESCE(p.company, 'Unassigned') AS company,
  COALESCE(p.platoon, 'Unassigned') AS platoon,
  'Cadet Private' AS rank,
  'Emergency Contact' AS emergency_contact_name,
  'Parent/Guardian' AS emergency_contact_relationship,
  'N/A'           AS emergency_contact_phone
FROM public.profiles p
WHERE p.role = 'cadet'
  AND p.status = 'approved'
  AND NOT EXISTS (
    SELECT 1 FROM public.cadets c WHERE c.profile_id = p.id
  );

-- STEP 2: Verify — count profiles vs cadets rows (should match)
SELECT
  (SELECT COUNT(*) FROM public.profiles WHERE role = 'cadet' AND status = 'approved') AS approved_cadet_profiles,
  (SELECT COUNT(*) FROM public.cadets) AS cadets_rows;

-- STEP 3: Show any remaining profiles that still have no cadets row
SELECT p.id, p.first_name, p.last_name, p.student_id, p.status
FROM public.profiles p
WHERE p.role = 'cadet'
  AND NOT EXISTS (SELECT 1 FROM public.cadets c WHERE c.profile_id = p.id)
ORDER BY p.last_name;

