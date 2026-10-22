-- ============================================================================
-- FILE: create_admin_account.sql
-- PURPOSE: 
--   Directly provisions a 100% pre-confirmed Administrator account in Supabase
--   with correct auth.users, auth.identities, and public.profiles records.
--
-- HOW TO RUN:
--   1. Open your Supabase Dashboard (https://supabase.com/dashboard)
--   2. Click "SQL Editor" on the left menu -> click "+ New Query"
--   3. Paste this ENTIRE script and click "RUN"
--   4. Log in immediately at http://localhost:3000/login.html with:
--        Email:    admin@rotcims.com
--        Password: AdminPassword123!
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
DECLARE
  v_user_id uuid := gen_random_uuid();
  v_email   text := 'admin@rotcims.com';
  v_pass    text := 'AdminPassword123!';
BEGIN
  -- 1. Remove any previous broken or pending records for this email
  DELETE FROM public.profiles WHERE email = v_email;
  DELETE FROM auth.identities WHERE identity_data->>'email' = v_email;
  DELETE FROM auth.users WHERE email = v_email;

  -- 2. Insert into auth.users as PRE-CONFIRMED (skips email verification)
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    recovery_sent_at,
    last_sign_in_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    recovery_token
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    v_user_id,
    'authenticated',
    'authenticated',
    v_email,
    crypt(v_pass, gen_salt('bf')),
    now(),
    null,
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"first_name":"Commandant","last_name":"Administrator"}'::jsonb,
    now(),
    now(),
    '',
    '',
    '',
    ''
  );

  -- 3. Insert linked identity into auth.identities (CRITICAL for GoTrue)
  INSERT INTO auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    provider_id,
    last_sign_in_at,
    created_at,
    updated_at
  ) VALUES (
    gen_random_uuid(),
    v_user_id,
    format('{"sub":"%s","email":"%s"}', v_user_id::text, v_email)::jsonb,
    'email',
    v_user_id::text,
    now(),
    now(),
    now()
  );

  -- 4. Insert into public.profiles as approved 'admin'
  INSERT INTO public.profiles (
    user_id,
    first_name,
    last_name,
    student_id,
    email,
    phone,
    course,
    year_level,
    section,
    date_of_birth,
    address,
    role,
    status
  ) VALUES (
    v_user_id,
    'Commandant',
    'Administrator',
    'ADMIN-001',
    v_email,
    '09123456789',
    'DMST',
    'Staff',
    'HQ',
    '1990-01-01',
    'San Enrique ROTC Headquarters',
    'admin',
    'approved'
  );

  RAISE NOTICE 'SUCCESS: Admin account % created and pre-confirmed!', v_email;
END $$;
