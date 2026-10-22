-- ============================================================================
-- FILE: create_posts_table.sql
-- PURPOSE: Adds unified "posts" table for the POSTING feature.
--          Supports multi-image collages (JSON array of image URLs/Base64),
--          category routing (gallery, events, announcements, requirements),
--          and public read / admin manage RLS policies.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  caption text NOT NULL,
  category text NOT NULL CHECK (category IN ('gallery', 'events', 'announcements', 'requirements')),
  images jsonb NOT NULL DEFAULT '[]'::jsonb, -- array of strings: ["url1", "url2", ...]
  event_date date,
  location text,
  uniform_info text,
  album_name text,
  priority text DEFAULT 'normal',
  is_published boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Index for speedy ordering by newest post first
CREATE INDEX IF NOT EXISTS posts_created_at_idx ON public.posts(created_at DESC);
CREATE INDEX IF NOT EXISTS posts_category_idx ON public.posts(category);

-- Enable RLS
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

-- Select policy: Anyone can see published posts, Admins see all
DROP POLICY IF EXISTS "posts_select_published" ON public.posts;
CREATE POLICY "posts_select_published" ON public.posts FOR SELECT USING (
  is_published = true OR public.current_profile_role() IN ('admin', 'personnel')
);

-- Manage policy: Admins and personnel can insert, update, delete
DROP POLICY IF EXISTS "posts_manage_admin" ON public.posts;
CREATE POLICY "posts_manage_admin" ON public.posts FOR ALL USING (
  public.current_profile_role() IN ('admin', 'personnel')
);

-- Seed an initial sample post matching the user's official military milestone
INSERT INTO public.posts (
  title,
  caption,
  category,
  album_name,
  images,
  is_published
) VALUES (
  'A MILESTONE FILLED WITH DISCIPLINE, HONOR, AND PRIDE 🫡 🇵🇭',
  'Behind every sharp salute, every synchronized march, and every tactical drill is a cadet and command cadre who never gets tired of believing in our mission. Today, the 604th CDC San Enrique ROTC Family comes together to salute the courage, patience, and dedication of all participating cadets.

Our tactical instructors and student officers guide us not only in the rules of military science and parade decorum, but also in the enduring values of duty, leadership, and patriotism that will define our generation. Your passion inspires us, and your commitment makes our ROTC journey meaningful.

May this training assembly remind each cadet of the honor and responsibility we uphold for our school, our community, and the Republic of the Philippines.

With honor and discipline, Your San Enrique ROTC Family 🫡',
  'gallery',
  '1st Instruction & Orientation 2026',
  '[
    "assets/gallery/1st-instruction/instruction-1.jpg",
    "assets/gallery/1st-instruction/instruction-2.jpg",
    "assets/gallery/1st-instruction/instruction-3.jpg",
    "assets/gallery/1st-instruction/instruction-4.jpg",
    "assets/gallery/1st-instruction/instruction-5.jpg"
  ]'::jsonb,
  true
)
ON CONFLICT DO NOTHING;
