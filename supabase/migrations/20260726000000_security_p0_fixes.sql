-- =============================================================
-- P0 SECURITY SPRINT — Fix insecure RLS policies
-- =============================================================
-- SAFE TO RE-RUN: uses DROP IF EXISTS / OR REPLACE
-- Does not drop tables or modify schema structure
--
-- Changes:
--   "Menu_Items"   — remove OR true / WITH CHECK (true)
--   "Restaurants"  — remove OR true from ALL policy
--   "Reviews"      — remove OR true from INSERT check
-- =============================================================

-- =============================================================
-- TASK 1: Secure "Menu_Items"
-- =============================================================
-- BEFORE: FOR ALL USING (... OR true) WITH CHECK (true)
--         → Any authenticated user can insert/update/delete any item
-- AFTER:  SELECT unchanged (public read, no filtering),
--         INSERT/UPDATE/DELETE restricted to restaurant owner
-- =============================================================

DROP POLICY IF EXISTS "Anyone can read menu" ON public."Menu_Items";
DROP POLICY IF EXISTS "Owner manages menu" ON public."Menu_Items";

CREATE POLICY "Anyone can read menu items"
  ON public."Menu_Items"
  FOR SELECT
  USING (true);

CREATE POLICY "Merchant owners insert menu items"
  ON public."Menu_Items"
  FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM public."Restaurants"
    WHERE id = "Menu_Items".restaurant_id
      AND owner_id = auth.uid()::text
  ));

CREATE POLICY "Merchant owners update menu items"
  ON public."Menu_Items"
  FOR UPDATE
  USING (EXISTS (
    SELECT 1 FROM public."Restaurants"
    WHERE id = "Menu_Items".restaurant_id
      AND owner_id = auth.uid()::text
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public."Restaurants"
    WHERE id = "Menu_Items".restaurant_id
      AND owner_id = auth.uid()::text
  ));

CREATE POLICY "Merchant owners delete menu items"
  ON public."Menu_Items"
  FOR DELETE
  USING (EXISTS (
    SELECT 1 FROM public."Restaurants"
    WHERE id = "Menu_Items".restaurant_id
      AND owner_id = auth.uid()::text
  ));

-- =============================================================
-- TASK 2: Secure "Restaurants"
-- =============================================================
-- BEFORE: FOR ALL USING (owner_id = auth.uid()::text OR true)
--         WITH CHECK (owner_id = auth.uid()::text OR true)
--         → Any authenticated user can insert/update/delete any restaurant
-- AFTER:  SELECT unchanged (public read),
--         INSERT/UPDATE/DELETE restricted to owner_id
-- =============================================================

DROP POLICY IF EXISTS "Anyone can read restaurants" ON public."Restaurants";
DROP POLICY IF EXISTS "Owner manages own restaurant" ON public."Restaurants";

CREATE POLICY "Anyone can read restaurants"
  ON public."Restaurants"
  FOR SELECT
  USING (true);

CREATE POLICY "Merchant owners insert restaurants"
  ON public."Restaurants"
  FOR INSERT
  WITH CHECK (owner_id = auth.uid()::text);

CREATE POLICY "Merchant owners update restaurants"
  ON public."Restaurants"
  FOR UPDATE
  USING (owner_id = auth.uid()::text)
  WITH CHECK (owner_id = auth.uid()::text);

CREATE POLICY "Merchant owners delete restaurants"
  ON public."Restaurants"
  FOR DELETE
  USING (owner_id = auth.uid()::text);

-- =============================================================
-- TASK 3: Fix "Reviews" policy
-- =============================================================
-- BEFORE: FOR INSERT WITH CHECK (user_id = auth.uid()::text OR true)
--         → Any authenticated user can create reviews as any user
-- AFTER:  SELECT unchanged (public read),
--         INSERT restricted to own user_id,
--         No UPDATE/DELETE (reviews are immutable)
-- =============================================================

DROP POLICY IF EXISTS "Anyone can read reviews" ON public."Reviews";
DROP POLICY IF EXISTS "Buyers create reviews for own orders" ON public."Reviews";

CREATE POLICY "Anyone can read reviews"
  ON public."Reviews"
  FOR SELECT
  USING (true);

CREATE POLICY "Buyers insert own reviews"
  ON public."Reviews"
  FOR INSERT
  WITH CHECK (user_id = auth.uid()::text);

-- No UPDATE or DELETE policies → reviews cannot be modified or deleted
-- by anyone after creation. This prevents merchants from altering
-- customer ratings or review text.

-- =============================================================
-- VERIFICATION (run in Supabase SQL Editor):
-- =============================================================
/*
SELECT schemaname, tablename, policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename IN ('Menu_Items', 'Restaurants', 'Reviews')
ORDER BY tablename, policyname;
*/
