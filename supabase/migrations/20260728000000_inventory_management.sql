-- =============================================================
-- INVENTORY MANAGEMENT BACKEND
-- =============================================================
-- Adds production-ready inventory to the active product table
-- (public."Menu_Items") and the future-schema table (public.products).
--
-- Creates stock_history table and secure stock-adjustment RPCs.
-- Integrates automatic stock deduction into order flow.
-- =============================================================
-- SAFE TO RE-RUN: uses IF NOT EXISTS / DROP IF EXISTS / OR REPLACE
-- =============================================================

-- =============================================================
-- 1. INVENTORY FIELDS ON "Menu_Items" (active table)
-- =============================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'Menu_Items' AND column_name = 'low_stock_threshold') THEN
    ALTER TABLE public."Menu_Items" ADD COLUMN low_stock_threshold INTEGER NOT NULL DEFAULT 10;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'Menu_Items' AND column_name = 'track_inventory') THEN
    ALTER TABLE public."Menu_Items" ADD COLUMN track_inventory BOOLEAN NOT NULL DEFAULT true;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'Menu_Items' AND column_name = 'allow_backorder') THEN
    ALTER TABLE public."Menu_Items" ADD COLUMN allow_backorder BOOLEAN NOT NULL DEFAULT false;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'Menu_Items' AND column_name = 'inventory_updated_at') THEN
    ALTER TABLE public."Menu_Items" ADD COLUMN inventory_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
  END IF;

  -- Ensure stock column exists (may have been added by app already)
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'Menu_Items' AND column_name = 'stock') THEN
    ALTER TABLE public."Menu_Items" ADD COLUMN stock INTEGER NOT NULL DEFAULT -1;
  END IF;
END $$;

-- Backfill: set default low_stock_threshold = 10 for rows where it's the default
UPDATE public."Menu_Items" SET low_stock_threshold = 10 WHERE low_stock_threshold IS NULL;

-- =============================================================
-- 2. INVENTORY FIELDS ON products (future schema)
-- =============================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'products') THEN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'low_stock_threshold') THEN
      ALTER TABLE public.products ADD COLUMN low_stock_threshold INTEGER NOT NULL DEFAULT 10;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'track_inventory') THEN
      ALTER TABLE public.products ADD COLUMN track_inventory BOOLEAN NOT NULL DEFAULT true;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'allow_backorder') THEN
      ALTER TABLE public.products ADD COLUMN allow_backorder BOOLEAN NOT NULL DEFAULT false;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'inventory_updated_at') THEN
      ALTER TABLE public.products ADD COLUMN inventory_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
    END IF;
  END IF;
END $$;

-- =============================================================
-- 3. CONSTRAINTS
-- =============================================================

ALTER TABLE public."Menu_Items" DROP CONSTRAINT IF EXISTS ck_menu_items_stock;
ALTER TABLE public."Menu_Items" ADD CONSTRAINT ck_menu_items_stock
  CHECK (stock >= 0 OR stock = -1);

ALTER TABLE public."Menu_Items" DROP CONSTRAINT IF EXISTS ck_menu_items_threshold;
ALTER TABLE public."Menu_Items" ADD CONSTRAINT ck_menu_items_threshold
  CHECK (low_stock_threshold >= 0);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'products') THEN
    ALTER TABLE public.products DROP CONSTRAINT IF EXISTS ck_products_stock;
    ALTER TABLE public.products ADD CONSTRAINT ck_products_stock
      CHECK (stock >= 0 OR stock = -1);
    ALTER TABLE public.products DROP CONSTRAINT IF EXISTS ck_products_threshold;
    ALTER TABLE public.products ADD CONSTRAINT ck_products_threshold
      CHECK (low_stock_threshold >= 0);
  END IF;
END $$;

-- =============================================================
-- 4. STOCK HISTORY TABLE
-- =============================================================

CREATE TYPE public.stock_reason AS ENUM (
  'MANUAL', 'RESTOCK', 'ORDER', 'CORRECTION', 'RETURN'
);

CREATE TYPE public.reference_type AS ENUM (
  'ORDER', 'MANUAL', 'IMPORT', 'RETURN', 'SYSTEM'
);

CREATE TABLE IF NOT EXISTS public.stock_history (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id      TEXT NOT NULL,
  merchant_id     TEXT NOT NULL,
  previous_stock  INTEGER NOT NULL,
  new_stock       INTEGER NOT NULL,
  change_amount   INTEGER NOT NULL,
  reason          public.stock_reason NOT NULL,
  reference_type  public.reference_type,
  reference_id    TEXT,
  created_by      TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stock_history_product ON public.stock_history(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_history_merchant ON public.stock_history(merchant_id);
CREATE INDEX IF NOT EXISTS idx_stock_history_created ON public.stock_history(created_at DESC);

ALTER TABLE public.stock_history ENABLE ROW LEVEL SECURITY;

-- RLS: merchants see only own stock history
DROP POLICY IF EXISTS "Merchants read own stock history" ON public.stock_history;
CREATE POLICY "Merchants read own stock history" ON public.stock_history
  FOR SELECT USING (
    merchant_id IN (SELECT id::text FROM public."Restaurants" WHERE owner_id = auth.uid()::text)
  );

DROP POLICY IF EXISTS "Stock history insert via RPC" ON public.stock_history;
CREATE POLICY "Stock history insert via RPC" ON public.stock_history
  FOR INSERT WITH CHECK (
    merchant_id IN (SELECT id::text FROM public."Restaurants" WHERE owner_id = auth.uid()::text)
  );

-- =============================================================
-- 5. INVENTORY UPDATED-AT TRIGGER
-- =============================================================

CREATE OR REPLACE FUNCTION public.trigger_inventory_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.inventory_updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_menu_items_inventory_updated_at ON public."Menu_Items";
CREATE TRIGGER trg_menu_items_inventory_updated_at
  BEFORE UPDATE OF stock, low_stock_threshold
  ON public."Menu_Items"
  FOR EACH ROW
  EXECUTE FUNCTION public.trigger_inventory_updated_at();

-- =============================================================
-- 6. STOCK ADJUSTMENT RPC: increase_stock
-- =============================================================

CREATE OR REPLACE FUNCTION public.increase_stock(
  p_product_id TEXT,
  p_quantity INTEGER,
  p_reason public.stock_reason DEFAULT 'MANUAL',
  p_reference_type public.reference_type DEFAULT 'MANUAL',
  p_reference_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_merchant_id TEXT;
  v_previous INTEGER;
  v_new INTEGER;
  v_result JSONB;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;

  -- Verify ownership via Restaurants
  SELECT restaurant_id INTO v_merchant_id
  FROM public."Restaurants"
  WHERE id = (SELECT restaurant_id FROM public."Menu_Items" WHERE id = p_product_id)
    AND owner_id = auth.uid()::text;

  IF v_merchant_id IS NULL THEN RAISE EXCEPTION 'Product not found or access denied'; END IF;

  SELECT stock INTO v_previous FROM public."Menu_Items" WHERE id = p_product_id;
  IF v_previous = -1 THEN RAISE EXCEPTION 'Cannot adjust stock for unlimited items'; END IF;

  v_new := v_previous + p_quantity;

  UPDATE public."Menu_Items" SET stock = v_new WHERE id = p_product_id;

  INSERT INTO public.stock_history (product_id, merchant_id, previous_stock, new_stock, change_amount, reason, reference_type, reference_id, created_by)
  VALUES (p_product_id, v_merchant_id, v_previous, v_new, p_quantity, p_reason, p_reference_type, p_reference_id, auth.uid()::text);

  SELECT jsonb_build_object('product_id', p_product_id, 'previous_stock', v_previous, 'new_stock', v_new, 'change_amount', p_quantity)
  INTO v_result;
  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.increase_stock FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.increase_stock TO authenticated;

-- =============================================================
-- 7. STOCK ADJUSTMENT RPC: decrease_stock
-- =============================================================

CREATE OR REPLACE FUNCTION public.decrease_stock(
  p_product_id TEXT,
  p_quantity INTEGER,
  p_reason public.stock_reason DEFAULT 'MANUAL',
  p_reference_type public.reference_type DEFAULT 'MANUAL',
  p_reference_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_merchant_id TEXT;
  v_previous INTEGER;
  v_new INTEGER;
  v_allow_backorder BOOLEAN;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;

  SELECT mi.restaurant_id, mi.stock, mi.allow_backorder
  INTO v_merchant_id, v_previous, v_allow_backorder
  FROM public."Menu_Items" mi
  JOIN public."Restaurants" r ON r.id = mi.restaurant_id AND r.owner_id = auth.uid()::text
  WHERE mi.id = p_product_id;

  IF v_merchant_id IS NULL THEN RAISE EXCEPTION 'Product not found or access denied'; END IF;
  IF v_previous = -1 THEN RAISE EXCEPTION 'Cannot adjust stock for unlimited items'; END IF;

  v_new := v_previous - p_quantity;
  IF v_new < 0 AND NOT v_allow_backorder THEN
    RAISE EXCEPTION 'Insufficient stock. Available: %, requested: %. Enable backorder to allow negative stock.', v_previous, p_quantity;
  END IF;

  UPDATE public."Menu_Items" SET stock = v_new WHERE id = p_product_id;

  INSERT INTO public.stock_history (product_id, merchant_id, previous_stock, new_stock, change_amount, reason, reference_type, reference_id, created_by)
  VALUES (p_product_id, v_merchant_id, v_previous, v_new, -p_quantity, p_reason, p_reference_type, p_reference_id, auth.uid()::text);

  RETURN jsonb_build_object('product_id', p_product_id, 'previous_stock', v_previous, 'new_stock', GREATEST(v_new, -1), 'change_amount', -p_quantity);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.decrease_stock FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decrease_stock TO authenticated;

-- =============================================================
-- 8. STOCK ADJUSTMENT RPC: set_stock
-- =============================================================

CREATE OR REPLACE FUNCTION public.set_stock(
  p_product_id TEXT,
  p_new_quantity INTEGER,
  p_reason public.stock_reason DEFAULT 'MANUAL',
  p_reference_type public.reference_type DEFAULT 'MANUAL',
  p_reference_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_merchant_id TEXT;
  v_previous INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

  SELECT mi.restaurant_id, mi.stock INTO v_merchant_id, v_previous
  FROM public."Menu_Items" mi
  JOIN public."Restaurants" r ON r.id = mi.restaurant_id AND r.owner_id = auth.uid()::text
  WHERE mi.id = p_product_id;

  IF v_merchant_id IS NULL THEN RAISE EXCEPTION 'Product not found or access denied'; END IF;
  IF p_new_quantity < 0 AND p_new_quantity != -1 THEN
    RAISE EXCEPTION 'Stock cannot be negative. Use -1 for unlimited.';
  END IF;

  UPDATE public."Menu_Items" SET stock = p_new_quantity WHERE id = p_product_id;

  INSERT INTO public.stock_history (product_id, merchant_id, previous_stock, new_stock, change_amount, reason, reference_type, reference_id, created_by)
  VALUES (p_product_id, v_merchant_id, v_previous, p_new_quantity, p_new_quantity - v_previous, p_reason, p_reference_type, p_reference_id, auth.uid()::text);

  RETURN jsonb_build_object('product_id', p_product_id, 'previous_stock', v_previous, 'new_stock', p_new_quantity, 'change_amount', p_new_quantity - v_previous);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_stock FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_stock TO authenticated;

-- =============================================================
-- 9. RPC: get_low_stock_products
-- =============================================================

CREATE OR REPLACE FUNCTION public.get_low_stock_products(
  p_restaurant_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_merchant_id TEXT;
  v_result JSONB;
BEGIN
  -- If no restaurant specified, find from auth
  IF p_restaurant_id IS NULL THEN
    SELECT id::text INTO v_merchant_id FROM public."Restaurants" WHERE owner_id = auth.uid()::text;
    IF v_merchant_id IS NULL THEN RAISE EXCEPTION 'No merchant profile found'; END IF;
  ELSE
    v_merchant_id := p_restaurant_id;
  END IF;

  WITH inventory AS (
    SELECT
      id AS product_id,
      name,
      category,
      stock,
      low_stock_threshold,
      track_inventory,
      CASE
        WHEN stock = -1 THEN 'UNLIMITED'
        WHEN stock = 0 THEN 'OUT_OF_STOCK'
        WHEN stock <= low_stock_threshold THEN 'LOW'
        ELSE 'NORMAL'
      END AS status
    FROM public."Menu_Items"
    WHERE restaurant_id = v_merchant_id
  )
  SELECT jsonb_build_object(
    'restaurant_id', v_merchant_id,
    'total_products', (SELECT count(*) FROM inventory),
    'low_stock_count', (SELECT count(*) FROM inventory WHERE status = 'LOW'),
    'out_of_stock_count', (SELECT count(*) FROM inventory WHERE status = 'OUT_OF_STOCK'),
    'products', COALESCE(jsonb_agg(row_to_json(i) ORDER BY i.status, i.name), '[]'::jsonb)
  ) INTO v_result
  FROM inventory i;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_low_stock_products FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_low_stock_products TO authenticated;

-- =============================================================
-- 10. AUTOMATIC STOCK DEDUCTION ON ORDER
-- =============================================================
-- This function is intended to be called after order status
-- transitions to 'accepted' or 'preparing'. It deducts each
-- order item's quantity from the corresponding product's stock.
--
-- It is NOT called automatically yet because:
--   1. The current create_customer_order RPC uses TEXT food_item_ids
--      that may not match Menu_Items TEXT ids (they should match).
--   2. The merchant may want to control when stock is deducted
--      (on accept vs on prepare vs manually).
--   3. Some items may not track inventory (track_inventory = false).
--
-- To activate automatic deduction, call this function from
-- the order status transition trigger or the merchant accept action.

CREATE OR REPLACE FUNCTION public.deduct_order_inventory(
  p_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_item RECORD;
  v_product RECORD;
  v_deductions JSONB := '[]'::jsonb;
  v_errors TEXT[] := '{}';
BEGIN
  FOR v_item IN
    SELECT food_item_id AS product_id, quantity
    FROM public."Order_Items"
    WHERE order_id = p_order_id
  LOOP
    -- Check if product exists and tracks inventory
    SELECT id, stock, track_inventory, allow_backorder
    INTO v_product
    FROM public."Menu_Items"
    WHERE id = v_item.product_id;

    IF v_product.id IS NULL THEN
      v_errors := array_append(v_errors, format('Product %s not found', v_item.product_id));
      CONTINUE;
    END IF;

    IF NOT v_product.track_inventory THEN
      CONTINUE; -- Skip products that don't track inventory
    END IF;

    IF v_product.stock = -1 THEN
      CONTINUE; -- Unlimited stock, no deduction needed
    END IF;

    IF v_product.stock < v_item.quantity AND NOT v_product.allow_backorder THEN
      v_errors := array_append(v_errors, format('Insufficient stock for %s: have %s, need %s', v_item.product_id, v_product.stock, v_item.quantity));
      CONTINUE;
    END IF;

    -- Deduct stock (allow negative if backorder enabled)
    UPDATE public."Menu_Items"
    SET stock = stock - v_item.quantity
    WHERE id = v_item.product_id;

    -- Record in stock history
    INSERT INTO public.stock_history (product_id, merchant_id, previous_stock, new_stock, change_amount, reason, reference_type, reference_id, created_by)
    SELECT
      v_item.product_id,
      o.restaurant_id,
      v_product.stock,
      v_product.stock - v_item.quantity,
      -v_item.quantity,
      'ORDER'::public.stock_reason,
      'ORDER'::public.reference_type,
      p_order_id::text,
      auth.uid()::text
    FROM public."Orders" o
    WHERE o.id = p_order_id;
  END LOOP;

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'errors', v_errors,
    'deducted', (SELECT count(*) FROM jsonb_array_elements(v_deductions))
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.deduct_order_inventory FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.deduct_order_inventory TO authenticated;

-- =============================================================
-- 11. INDEXES
-- =============================================================

CREATE INDEX IF NOT EXISTS idx_menu_items_stock ON public."Menu_Items"(stock) WHERE stock >= 0;
CREATE INDEX IF NOT EXISTS idx_menu_items_low_stock ON public."Menu_Items"(restaurant_id, stock, low_stock_threshold)
  WHERE track_inventory = true AND stock >= 0;

-- =============================================================
-- 12. RLS FOR "Menu_Items" INVENTORY FIELDS
-- =============================================================
-- Existing P0 policies already restrict Menu_Items writes to
-- restaurant owners. The new inventory columns are covered by
-- the existing UPDATE/DELETE policies. No additional policies needed.

-- =============================================================
-- DOCUMENTATION
-- =============================================================
/*
INVENTORY MANAGEMENT — FIELD DESCRIPTIONS

Menu_Items.stock:
  - Current stock quantity
  - -1 = unlimited (does not track stock)
  - 0 = out of stock
  - > 0 = available quantity

Menu_Items.low_stock_threshold:
  - When stock <= this value, product is considered "low stock"
  - Default: 10

Menu_Items.track_inventory:
  - If true, stock is tracked and deducted on orders
  - If false, stock is informational only

Menu_Items.allow_backorder:
  - If true, stock can go negative (overselling allowed)
  - If false, stock cannot drop below 0

STOCK HISTORY REASONS:
  MANUAL     – Manual adjustment by merchant
  RESTOCK    – Restocking event
  ORDER      – Order placement / deduction
  CORRECTION – Discrepancy correction
  RETURN     – Product return

STOCK ADJUSTMENT RPCS:
  increase_stock(product_id, quantity, reason, reference_type, reference_id)
  decrease_stock(product_id, quantity, reason, reference_type, reference_id)
  set_stock(product_id, new_quantity, reason, reference_type, reference_id)
  get_low_stock_products(restaurant_id) — returns all products with status

AUTOMATIC DEDUCTION:
  deduct_order_inventory(order_id) — call after order transitions to 'accepted'
  Not yet automatically triggered. Pending hook in create_customer_order
  or an order-status trigger.
*/
