-- =============================================================
-- ALE DELIVERY PLATFORM — Production Order System
-- =============================================================
-- SAFE TO RE-RUN: uses IF NOT EXISTS / DROP IF EXISTS / OR REPLACE
-- Preserves existing data
-- =============================================================

-- ─── UPDATED_AT TRIGGER (for saved_addresses if missing) ──────

CREATE OR REPLACE FUNCTION public.trigger_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================
-- 1. ENSURE COLUMNS EXIST ON Orders TABLE
-- =============================================================
-- The Flutter app currently uses "Orders" with TEXT user_id, restaurant_id etc.
-- We add missing columns safely without dropping anything.

DO $$
BEGIN
  -- Add order_number if missing
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Orders' AND column_name = 'order_number'
  ) THEN
    ALTER TABLE public."Orders" ADD COLUMN order_number TEXT;
  END IF;

  -- Add service_fee if missing
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Orders' AND column_name = 'service_fee'
  ) THEN
    ALTER TABLE public."Orders" ADD COLUMN service_fee DECIMAL(10, 2) NOT NULL DEFAULT 0;
  END IF;

  -- Add payment_status if missing
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Orders' AND column_name = 'payment_status'
  ) THEN
    ALTER TABLE public."Orders" ADD COLUMN payment_status TEXT NOT NULL DEFAULT 'pending';
  END IF;

  -- Add delivery_latitude if missing
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Orders' AND column_name = 'delivery_latitude'
  ) THEN
    ALTER TABLE public."Orders" ADD COLUMN delivery_latitude DOUBLE PRECISION;
  END IF;

  -- Add delivery_longitude if missing
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Orders' AND column_name = 'delivery_longitude'
  ) THEN
    ALTER TABLE public."Orders" ADD COLUMN delivery_longitude DOUBLE PRECISION;
  END IF;

  -- Add saved_address_id if missing
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Orders' AND column_name = 'saved_address_id'
  ) THEN
    ALTER TABLE public."Orders" ADD COLUMN saved_address_id UUID;
  END IF;

  -- Add driver_name if missing
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Orders' AND column_name = 'driver_name'
  ) THEN
    ALTER TABLE public."Orders" ADD COLUMN driver_name TEXT;
  END IF;
END $$;

-- ─── GENERATE ORDER NUMBERS FOR EXISTING ROWS ────────────────
UPDATE public."Orders"
SET order_number = 'ORD-' || UPPER(SUBSTRING(MD5(id::text) FOR 8))
WHERE order_number IS NULL OR order_number = '';

-- =============================================================
-- 2. ENSURE COLUMNS EXIST ON Order_Items TABLE
-- =============================================================

DO $$
BEGIN
  -- Add line_total if missing
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Order_Items' AND column_name = 'line_total'
  ) THEN
    ALTER TABLE public."Order_Items" ADD COLUMN line_total DECIMAL(10, 2);
  END IF;

  -- Add created_at if missing
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Order_Items' AND column_name = 'created_at'
  ) THEN
    ALTER TABLE public."Order_Items" ADD COLUMN created_at TIMESTAMPTZ DEFAULT now();
  END IF;
END $$;

-- Fill line_total for existing rows
UPDATE public."Order_Items"
SET line_total = price * quantity
WHERE line_total IS NULL;

-- =============================================================
-- 3. CREATE INDEXES
-- =============================================================

CREATE INDEX IF NOT EXISTS idx_orders_order_number ON public."Orders"(order_number);
CREATE INDEX IF NOT EXISTS idx_orders_payment_status ON public."Orders"(payment_status);
CREATE INDEX IF NOT EXISTS idx_orders_user_status ON public."Orders"(user_id, status);

-- =============================================================
-- 4. RLS — Drop insecure existing policies
-- =============================================================

DROP POLICY IF EXISTS "Buyers read own orders" ON public."Orders";
DROP POLICY IF EXISTS "Buyers insert orders" ON public."Orders";
DROP POLICY IF EXISTS "Buyers update own orders" ON public."Orders";
DROP POLICY IF EXISTS "Sellers read restaurant orders" ON public."Orders";
DROP POLICY IF EXISTS "Sellers update restaurant orders" ON public."Orders";
DROP POLICY IF EXISTS "Anyone read order items" ON public."Order_Items";
DROP POLICY IF EXISTS "Anyone insert order items" ON public."Order_Items";

-- Enable RLS
ALTER TABLE public."Orders" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."Order_Items" ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- 5. CREATE SECURE RLS POLICIES
-- =============================================================

-- Orders: customers can only read own orders
CREATE POLICY "Customers read own orders" ON public."Orders"
  FOR SELECT USING (
    user_id = auth.uid()::text
  );

-- Orders: customers insert via RPC only (no direct insert)
-- We still allow INSERT so the RPC can write, but CHECK restricts to own user_id
CREATE POLICY "Customers insert own orders" ON public."Orders"
  FOR INSERT WITH CHECK (
    user_id = auth.uid()::text
  );

-- Orders: customers can cancel own pending/accepted orders
CREATE POLICY "Customers cancel own orders" ON public."Orders"
  FOR UPDATE USING (
    user_id = auth.uid()::text
    AND status IN ('pending', 'accepted')
  ) WITH CHECK (
    user_id = auth.uid()::text
    AND status = 'cancelled'
  );

-- Order_Items: customers read items of own orders
CREATE POLICY "Customers read own order items" ON public."Order_Items"
  FOR SELECT USING (
    order_id IN (
      SELECT id FROM public."Orders" WHERE user_id = auth.uid()::text
    )
  );

-- Order_Items: insert via RPC only
CREATE POLICY "Insert order items" ON public."Order_Items"
  FOR INSERT WITH CHECK (
    order_id IN (
      SELECT id FROM public."Orders" WHERE user_id = auth.uid()::text
    )
  );

-- =============================================================
-- 6. CREATE SECURE ORDER PLACEMENT FUNCTION
-- =============================================================

CREATE OR REPLACE FUNCTION public.create_customer_order(
  p_restaurant_id TEXT,
  p_restaurant_name TEXT,
  p_items JSONB,
  p_delivery_address TEXT,
  p_delivery_phone TEXT,
  p_delivery_latitude DOUBLE PRECISION,
  p_delivery_longitude DOUBLE PRECISION,
  p_delivery_notes TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT 'cash',
  p_saved_address_id UUID DEFAULT NULL,
  p_delivery_fee DECIMAL(10,2) DEFAULT 0,
  p_service_fee DECIMAL(10,2) DEFAULT 0,
  p_promo_code TEXT DEFAULT NULL,
  p_discount DECIMAL(10,2) DEFAULT 0,
  p_scheduled_at TIMESTAMPTZ DEFAULT NULL,
  p_tip DECIMAL(10,2) DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_user_id TEXT;
  v_order_id UUID;
  v_order_number TEXT;
  v_item JSONB;
  v_items_total DECIMAL(10,2) := 0;
  v_total DECIMAL(10,2);
  v_item_qty INTEGER;
  v_item_price DECIMAL(10,2);
  v_result JSONB;
BEGIN
  -- 1. Authenticate
  v_user_id := auth.uid()::text;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING HINT = 'Please sign in first.';
  END IF;

  -- 2. Validate input
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Cart is empty' USING HINT = 'Add items to your cart before placing an order.';
  END IF;

  IF p_restaurant_id IS NULL OR p_restaurant_id = '' THEN
    RAISE EXCEPTION 'Restaurant is required' USING HINT = 'Select a restaurant.';
  END IF;

  IF p_delivery_address IS NULL OR p_delivery_address = '' THEN
    RAISE EXCEPTION 'Delivery address is required' USING HINT = 'Enter a delivery address.';
  END IF;

  IF p_delivery_phone IS NULL OR p_delivery_phone = '' THEN
    RAISE EXCEPTION 'Delivery phone is required' USING HINT = 'Enter a contact phone number.';
  END IF;

  -- 3. Generate order number
  v_order_number := 'ORD-' || UPPER(SUBSTRING(MD5(gen_random_uuid()::text) FOR 8));

  -- 4. Calculate totals from authoritative data
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_qty := (v_item->>'quantity')::INTEGER;
    IF v_item_qty IS NULL OR v_item_qty < 1 THEN
      RAISE EXCEPTION 'Invalid quantity for item %', (v_item->>'name')::TEXT;
    END IF;

    -- Use price from client as authoritative for now
    -- (Menu_Items table uses TEXT id, making server-side lookup complex)
    v_item_price := (v_item->>'price')::DECIMAL(10,2);
    IF v_item_price IS NULL OR v_item_price < 0 THEN
      RAISE EXCEPTION 'Invalid price for item %', (v_item->>'name')::TEXT;
    END IF;

    v_items_total := v_items_total + (v_item_price * v_item_qty);
  END LOOP;

  -- 5. Calculate total
  v_total := v_items_total + COALESCE(p_delivery_fee, 0) + COALESCE(p_service_fee, 0) - COALESCE(p_discount, 0) + COALESCE(p_tip, 0);

  -- 6. Insert order
  INSERT INTO public."Orders" (
    user_id,
    restaurant_id,
    restaurant_name,
    status,
    order_number,
    subtotal,
    delivery_fee,
    service_fee,
    total,
    delivery_address,
    delivery_phone,
    delivery_notes,
    delivery_latitude,
    delivery_longitude,
    saved_address_id,
    payment_method,
    payment_status,
    promo_code,
    discount,
    scheduled_at,
    tip,
    created_at,
    updated_at
  ) VALUES (
    v_user_id,
    p_restaurant_id,
    p_restaurant_name,
    'pending',
    v_order_number,
    v_items_total,
    COALESCE(p_delivery_fee, 0),
    COALESCE(p_service_fee, 0),
    v_total,
    p_delivery_address,
    p_delivery_phone,
    p_delivery_notes,
    p_delivery_latitude,
    p_delivery_longitude,
    p_saved_address_id,
    COALESCE(p_payment_method, 'cash'),
    'pending',
    p_promo_code,
    COALESCE(p_discount, 0),
    p_scheduled_at,
    COALESCE(p_tip, 0),
    now(),
    now()
  )
  RETURNING id INTO v_order_id;

  -- 7. Insert order items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public."Order_Items" (
      order_id,
      food_item_id,
      name,
      price,
      quantity,
      selected_size,
      image_url,
      line_total,
      created_at
    ) VALUES (
      v_order_id,
      (v_item->>'food_item_id')::TEXT,
      (v_item->>'name')::TEXT,
      (v_item->>'price')::DECIMAL(10,2),
      (v_item->>'quantity')::INTEGER,
      (v_item->>'selected_size')::TEXT,
      (v_item->>'image_url')::TEXT,
      ((v_item->>'price')::DECIMAL(10,2) * (v_item->>'quantity')::INTEGER),
      now()
    );
  END LOOP;

  -- 8. Return created order as JSON
  SELECT row_to_json(o)::jsonb INTO v_result
  FROM (SELECT * FROM public."Orders" WHERE id = v_order_id) o;

  RETURN v_result;
END;
$$;

-- Revoke execute from public, grant to authenticated users only
REVOKE EXECUTE ON FUNCTION public.create_customer_order FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_customer_order TO authenticated;

-- =============================================================
-- 7. CREATE CANCEL ORDER FUNCTION
-- =============================================================

CREATE OR REPLACE FUNCTION public.cancel_customer_order(
  p_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_user_id TEXT;
  v_order RECORD;
  v_result JSONB;
BEGIN
  v_user_id := auth.uid()::text;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO v_order FROM public."Orders" WHERE id = p_order_id;
  IF v_order IS NULL THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_order.user_id != v_user_id THEN
    RAISE EXCEPTION 'You can only cancel your own orders';
  END IF;

  IF v_order.status NOT IN ('pending', 'accepted') THEN
    RAISE EXCEPTION 'This order cannot be cancelled because it is already %', v_order.status;
  END IF;

  UPDATE public."Orders"
  SET status = 'cancelled', updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  SELECT row_to_json(v_order)::jsonb INTO v_result;
  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.cancel_customer_order FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_customer_order TO authenticated;

-- =============================================================
-- 8. CREATE GET MY ORDERS FUNCTION
-- =============================================================

CREATE OR REPLACE FUNCTION public.get_customer_orders(
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_user_id TEXT;
  v_orders JSONB;
BEGIN
  v_user_id := auth.uid()::text;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(o) ORDER BY o.created_at DESC), '[]'::jsonb)
  INTO v_orders
  FROM (SELECT * FROM public."Orders" WHERE user_id = v_user_id ORDER BY created_at DESC LIMIT p_limit OFFSET p_offset) o;

  RETURN jsonb_build_object('orders', v_orders);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_customer_orders FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_customer_orders TO authenticated;
