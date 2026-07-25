-- =============================================================
-- ALE DELIVERY PLATFORM — Complete Database Schema
-- =============================================================
-- NOTES:
--   Safe to re-run: uses IF NOT EXISTS / DROP IF EXISTS
--   All tables use UUID PKs + created_at/updated_at
--   updated_at triggers included for every table
--   Row Level Security enabled on all tables
--   Storage buckets + policies included
-- =============================================================

-- ─── EXTENSIONS ────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─── UPDATED_AT TRIGGER FUNCTION ──────────────────────────────

CREATE OR REPLACE FUNCTION trigger_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================
-- PROFILES
-- =============================================================
-- Extends auth.users. Every user gets a profile on signup.
-- Stores name, phone, avatar, and preferences.

CREATE TABLE IF NOT EXISTS profiles (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  phone         TEXT UNIQUE,
  email         TEXT,
  full_name     TEXT,
  avatar_url    TEXT,
  gender        TEXT CHECK (gender IN ('male', 'female', 'other')),
  birthday      DATE,
  is_active     BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_profiles_user_id ON profiles(user_id);
CREATE INDEX IF NOT EXISTS idx_profiles_phone ON profiles(phone);

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- ─── ROLE DEFINITIONS ─────────────────────────────────────────

CREATE TABLE IF NOT EXISTS roles (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT UNIQUE NOT NULL,
  description   TEXT,
  is_system     BOOLEAN DEFAULT false,
  created_at    TIMESTAMPTZ DEFAULT now()
);

INSERT INTO roles (name, description, is_system) VALUES
  ('customer', 'End-user who orders food, rides, parcels, or groceries', true),
  ('merchant', 'Restaurant, grocery, or store owner', true),
  ('driver', 'Ride/delivery driver partner', true),
  ('admin', 'Platform administrator', true)
ON CONFLICT (name) DO NOTHING;

ALTER TABLE roles ENABLE ROW LEVEL SECURITY;

-- ─── USER ROLES (many-to-many) ───────────────────────────────

CREATE TABLE IF NOT EXISTS user_roles (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  role_id       UUID REFERENCES roles(id) ON DELETE CASCADE,
  created_at    TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_user_roles_user_id ON user_roles(user_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_role_id ON user_roles(role_id);

ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;

-- ─── ADDRESSES ────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS addresses (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  label         TEXT DEFAULT 'Home',
  address_line  TEXT NOT NULL,
  city          TEXT,
  district      TEXT,
  province      TEXT,
  postal_code   TEXT,
  latitude      DOUBLE PRECISION,
  longitude     DOUBLE PRECISION,
  is_default    BOOLEAN DEFAULT false,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_addresses_user_id ON addresses(user_id);
CREATE INDEX IF NOT EXISTS idx_addresses_coords ON addresses(latitude, longitude);

DROP TRIGGER IF EXISTS trg_addresses_updated_at ON addresses;
CREATE TRIGGER trg_addresses_updated_at
  BEFORE UPDATE ON addresses
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE addresses ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- MERCHANT (RESTAURANT / STORE)
-- =============================================================

CREATE TABLE IF NOT EXISTS merchants (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id      UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  slug          TEXT UNIQUE,
  description   TEXT,
  cuisine       TEXT,
  logo_url      TEXT,
  banner_url    TEXT,
  address       TEXT,
  city          TEXT,
  district      TEXT,
  latitude      DOUBLE PRECISION,
  longitude     DOUBLE PRECISION,
  phone         TEXT,
  email         TEXT,
  service_type  TEXT[] DEFAULT ARRAY['food'], -- food, grocery, parcel
  delivery_fee  NUMERIC(10,2) DEFAULT 0,
  min_order     NUMERIC(10,2) DEFAULT 0,
  free_delivery_min NUMERIC(10,2) DEFAULT 0,
  delivery_time TEXT DEFAULT '25-35',
  rating        NUMERIC(3,2) DEFAULT 0,
  rating_count  INTEGER DEFAULT 0,
  is_active     BOOLEAN DEFAULT true,
  is_verified   BOOLEAN DEFAULT false,
  opens_at      TIME,
  closes_at     TIME,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_merchants_owner ON merchants(owner_id);
CREATE INDEX IF NOT EXISTS idx_merchants_city ON merchants(city);
CREATE INDEX IF NOT EXISTS idx_merchants_coords ON merchants(latitude, longitude);
CREATE INDEX IF NOT EXISTS idx_merchants_service_type ON merchants USING GIN(service_type);
CREATE INDEX IF NOT EXISTS idx_merchants_active ON merchants(is_active) WHERE is_active = true;

DROP TRIGGER IF EXISTS trg_merchants_updated_at ON merchants;
CREATE TRIGGER trg_merchants_updated_at
  BEFORE UPDATE ON merchants
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE merchants ENABLE ROW LEVEL SECURITY;

-- ─── MERCHANT STAFF ───────────────────────────────────────────

CREATE TABLE IF NOT EXISTS merchant_staff (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id   UUID REFERENCES merchants(id) ON DELETE CASCADE,
  user_id       UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  role          TEXT DEFAULT 'staff' CHECK (role IN ('owner', 'manager', 'staff', 'chef')),
  is_active     BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT now(),
  UNIQUE(merchant_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_merchant_staff_merchant ON merchant_staff(merchant_id);
CREATE INDEX IF NOT EXISTS idx_merchant_staff_user ON merchant_staff(user_id);

ALTER TABLE merchant_staff ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- CATEGORIES
-- =============================================================
-- Merchant-specific categories (e.g., Burgers, Pizza for food;
-- Fruits, Vegetables for grocery).

CREATE TABLE IF NOT EXISTS categories (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id   UUID REFERENCES merchants(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  icon          TEXT,
  color         TEXT DEFAULT '#F59E0B',
  description   TEXT,
  sort_order    INTEGER DEFAULT 0,
  is_active     BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_categories_merchant ON categories(merchant_id);
CREATE INDEX IF NOT EXISTS idx_categories_sort ON categories(merchant_id, sort_order);

DROP TRIGGER IF EXISTS trg_categories_updated_at ON categories;
CREATE TRIGGER trg_categories_updated_at
  BEFORE UPDATE ON categories
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE categories ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- PRODUCTS
-- =============================================================

CREATE TABLE IF NOT EXISTS products (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id   UUID REFERENCES merchants(id) ON DELETE CASCADE,
  category_id   UUID REFERENCES categories(id) ON DELETE SET NULL,
  name          TEXT NOT NULL,
  description   TEXT,
  price         NUMERIC(10,2) NOT NULL,
  compare_price NUMERIC(10,2), -- original price for discount display
  unit          TEXT DEFAULT '1pc', -- kg, L, pc, box
  stock         INTEGER DEFAULT -1, -- -1 = unlimited
  is_featured   BOOLEAN DEFAULT false,
  is_active     BOOLEAN DEFAULT true,
  rating        NUMERIC(3,2) DEFAULT 0,
  rating_count  INTEGER DEFAULT 0,
  prep_time     INTEGER, -- minutes
  tags          TEXT[],
  sizes         JSONB, -- e.g., ["Regular", "Large"] for food
  ingredients   TEXT[],
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_products_merchant ON products(merchant_id);
CREATE INDEX IF NOT EXISTS idx_products_category ON products(category_id);
CREATE INDEX IF NOT EXISTS idx_products_active ON products(is_active, is_featured) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_products_tags ON products USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_products_price ON products(price);

DROP TRIGGER IF EXISTS trg_products_updated_at ON products;
CREATE TRIGGER trg_products_updated_at
  BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE products ENABLE ROW LEVEL SECURITY;

-- ─── PRODUCT IMAGES ───────────────────────────────────────────

CREATE TABLE IF NOT EXISTS product_images (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id    UUID REFERENCES products(id) ON DELETE CASCADE,
  url           TEXT NOT NULL,
  alt_text      TEXT,
  sort_order    INTEGER DEFAULT 0,
  is_primary    BOOLEAN DEFAULT false,
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_product_images_product ON product_images(product_id);
CREATE INDEX IF NOT EXISTS idx_product_images_primary ON product_images(product_id, is_primary) WHERE is_primary = true;

ALTER TABLE product_images ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- ORDERS
-- =============================================================
-- Supports: Food, Grocery, Parcel, and future order types.
-- Polymorphic via order_type + reference_id.

CREATE TYPE order_status AS ENUM (
  'pending', 'accepted', 'preparing', 'ready',
  'on_the_way', 'delivered', 'cancelled', 'refunded'
);

CREATE TYPE order_type AS ENUM (
  'food', 'grocery', 'parcel', 'ride'
);

CREATE TABLE IF NOT EXISTS orders (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  merchant_id     UUID REFERENCES merchants(id) ON DELETE SET NULL,
  driver_id       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  order_type      order_type NOT NULL,
  status          order_status DEFAULT 'pending',
  items_total     NUMERIC(10,2) NOT NULL DEFAULT 0,
  delivery_fee    NUMERIC(10,2) DEFAULT 0,
  service_fee     NUMERIC(10,2) DEFAULT 0,
  tip             NUMERIC(10,2) DEFAULT 0,
  discount        NUMERIC(10,2) DEFAULT 0,
  total           NUMERIC(10,2) NOT NULL,
  payment_method  TEXT DEFAULT 'cash',
  payment_status  TEXT DEFAULT 'pending' CHECK (payment_status IN ('pending', 'paid', 'failed', 'refunded')),
  delivery_address_id UUID REFERENCES addresses(id) ON DELETE SET NULL,
  delivery_address TEXT,
  delivery_notes  TEXT,
  delivery_lat    DOUBLE PRECISION,
  delivery_lng    DOUBLE PRECISION,
  pickup_address  TEXT,
  pickup_lat      DOUBLE PRECISION,
  pickup_lng      DOUBLE PRECISION,
  scheduled_at    TIMESTAMPTZ,
  driver_assigned_at TIMESTAMPTZ,
  delivered_at    TIMESTAMPTZ,
  cancelled_at    TIMESTAMPTZ,
  cancellation_reason TEXT,
  reference_id    UUID, -- polymorphic ref to ride_requests, parcel_requests
  metadata        JSONB,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_merchant ON orders(merchant_id);
CREATE INDEX IF NOT EXISTS idx_orders_driver ON orders(driver_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_type ON orders(order_type);
CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_scheduled ON orders(scheduled_at) WHERE scheduled_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_orders_active ON orders(user_id, status)
  WHERE status NOT IN ('delivered', 'cancelled');

DROP TRIGGER IF EXISTS trg_orders_updated_at ON orders;
CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- ─── ORDER ITEMS ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS order_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id      UUID REFERENCES orders(id) ON DELETE CASCADE,
  product_id    UUID REFERENCES products(id) ON DELETE SET NULL,
  name          TEXT NOT NULL,
  price         NUMERIC(10,2) NOT NULL,
  quantity      INTEGER NOT NULL DEFAULT 1,
  subtotal      NUMERIC(10,2) NOT NULL,
  selected_size TEXT,
  notes         TEXT,
  image_url     TEXT,
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);

ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- DRIVERS
-- =============================================================

CREATE TABLE IF NOT EXISTS drivers (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  full_name       TEXT NOT NULL,
  phone           TEXT UNIQUE NOT NULL,
  avatar_url      TEXT,
  vehicle_type    TEXT CHECK (vehicle_type IN ('bike', 'tuk', 'car', 'van', 'luxury')),
  vehicle_number  TEXT,
  vehicle_model   TEXT,
  license_number  TEXT,
  is_online       BOOLEAN DEFAULT false,
  is_active       BOOLEAN DEFAULT true,
  is_verified     BOOLEAN DEFAULT false,
  rating          NUMERIC(3,2) DEFAULT 5.0,
  rating_count    INTEGER DEFAULT 0,
  total_trips     INTEGER DEFAULT 0,
  current_lat     DOUBLE PRECISION,
  current_lng     DOUBLE PRECISION,
  last_location_update TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_drivers_online ON drivers(is_online) WHERE is_online = true;
CREATE INDEX IF NOT EXISTS idx_drivers_location ON drivers(current_lat, current_lng);
CREATE INDEX IF NOT EXISTS idx_drivers_vehicle ON drivers(vehicle_type);

DROP TRIGGER IF EXISTS trg_drivers_updated_at ON drivers;
CREATE TRIGGER trg_drivers_updated_at
  BEFORE UPDATE ON drivers
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE drivers ENABLE ROW LEVEL SECURITY;

-- ─── DRIVER LOCATIONS (high-frequency updates) ───────────────

CREATE TABLE IF NOT EXISTS driver_locations (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id     UUID REFERENCES drivers(id) ON DELETE CASCADE,
  latitude      DOUBLE PRECISION NOT NULL,
  longitude     DOUBLE PRECISION NOT NULL,
  heading       REAL,         -- compass direction in degrees
  speed         REAL,         -- m/s
  accuracy      REAL,         -- meters
  timestamp     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_driver_locations_driver ON driver_locations(driver_id);
CREATE INDEX IF NOT EXISTS idx_driver_locations_ts ON driver_locations(driver_id, timestamp DESC);
-- Enable PostGIS-friendly index for spatial queries
CREATE INDEX IF NOT EXISTS idx_driver_locations_geo ON driver_locations(latitude, longitude);

ALTER TABLE driver_locations ENABLE ROW LEVEL SECURITY;

-- ─── DRIVER JOBS (delivery/ride assignments) ─────────────────

CREATE TYPE job_status AS ENUM (
  'assigned', 'accepted', 'arrived', 'in_progress',
  'completed', 'cancelled'
);

CREATE TABLE IF NOT EXISTS driver_jobs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id       UUID REFERENCES drivers(id) ON DELETE CASCADE,
  order_id        UUID REFERENCES orders(id) ON DELETE CASCADE,
  status          job_status DEFAULT 'assigned',
  pickup_lat      DOUBLE PRECISION,
  pickup_lng      DOUBLE PRECISION,
  dropoff_lat     DOUBLE PRECISION,
  dropoff_lng     DOUBLE PRECISION,
  accepted_at     TIMESTAMPTZ,
  arrived_at      TIMESTAMPTZ,
  started_at      TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  cancelled_at    TIMESTAMPTZ,
  rating          INTEGER CHECK (rating >= 1 AND rating <= 5),
  rating_comment  TEXT,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_driver_jobs_driver ON driver_jobs(driver_id);
CREATE INDEX IF NOT EXISTS idx_driver_jobs_order ON driver_jobs(order_id);
CREATE INDEX IF NOT EXISTS idx_driver_jobs_status ON driver_jobs(status);
CREATE INDEX IF NOT EXISTS idx_driver_jobs_active ON driver_jobs(driver_id, status)
  WHERE status IN ('assigned', 'accepted', 'arrived', 'in_progress');

DROP TRIGGER IF EXISTS trg_driver_jobs_updated_at ON driver_jobs;
CREATE TRIGGER trg_driver_jobs_updated_at
  BEFORE UPDATE ON driver_jobs
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE driver_jobs ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- RIDE REQUESTS
-- =============================================================

CREATE TYPE ride_status AS ENUM (
  'searching', 'accepted', 'arriving', 'in_progress',
  'completed', 'cancelled'
);

CREATE TABLE IF NOT EXISTS ride_requests (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  driver_id       UUID REFERENCES drivers(id) ON DELETE SET NULL,
  status          ride_status DEFAULT 'searching',
  ride_type       TEXT NOT NULL CHECK (ride_type IN ('bike', 'tuk', 'car', 'van', 'luxury')),
  pickup_name     TEXT,
  pickup_lat      DOUBLE PRECISION NOT NULL,
  pickup_lng      DOUBLE PRECISION NOT NULL,
  dropoff_name    TEXT,
  dropoff_lat     DOUBLE PRECISION NOT NULL,
  dropoff_lng     DOUBLE PRECISION NOT NULL,
  distance_km     DOUBLE PRECISION,
  duration_min    INTEGER,
  base_fare       NUMERIC(10,2),
  distance_fare   NUMERIC(10,2),
  time_fare       NUMERIC(10,2),
  total_fare      NUMERIC(10,2),
  payment_method  TEXT DEFAULT 'cash',
  cancelled_by    TEXT CHECK (cancelled_by IN ('user', 'driver', 'system')),
  cancellation_reason TEXT,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ride_requests_user ON ride_requests(user_id);
CREATE INDEX IF NOT EXISTS idx_ride_requests_driver ON ride_requests(driver_id);
CREATE INDEX IF NOT EXISTS idx_ride_requests_status ON ride_requests(status);
CREATE INDEX IF NOT EXISTS idx_ride_requests_active ON ride_requests(status)
  WHERE status IN ('searching', 'accepted', 'arriving', 'in_progress');

DROP TRIGGER IF EXISTS trg_ride_requests_updated_at ON ride_requests;
CREATE TRIGGER trg_ride_requests_updated_at
  BEFORE UPDATE ON ride_requests
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE ride_requests ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- PARCEL REQUESTS
-- =============================================================

CREATE TYPE parcel_status AS ENUM (
  'pending', 'picked_up', 'in_transit', 'out_for_delivery',
  'delivered', 'cancelled'
);

CREATE TYPE parcel_size AS ENUM (
  'small', 'medium', 'large', 'extra_large'
);

CREATE TABLE IF NOT EXISTS parcel_requests (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  driver_id       UUID REFERENCES drivers(id) ON DELETE SET NULL,
  status          parcel_status DEFAULT 'pending',
  parcel_size     parcel_size DEFAULT 'small',
  description     TEXT,
  weight_kg       NUMERIC(5,2),
  image_url       TEXT,
  pickup_name     TEXT NOT NULL,
  pickup_lat      DOUBLE PRECISION NOT NULL,
  pickup_lng      DOUBLE PRECISION NOT NULL,
  pickup_address  TEXT,
  pickup_phone    TEXT,
  dropoff_name    TEXT NOT NULL,
  dropoff_lat     DOUBLE PRECISION NOT NULL,
  dropoff_lng     DOUBLE PRECISION NOT NULL,
  dropoff_address TEXT,
  dropoff_phone   TEXT,
  distance_km     DOUBLE PRECISION,
  total_fare      NUMERIC(10,2),
  payment_method  TEXT DEFAULT 'cash',
  is_fragile      BOOLEAN DEFAULT false,
  scheduled_at    TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_parcel_requests_user ON parcel_requests(user_id);
CREATE INDEX IF NOT EXISTS idx_parcel_requests_driver ON parcel_requests(driver_id);
CREATE INDEX IF NOT EXISTS idx_parcel_requests_status ON parcel_requests(status);
CREATE INDEX IF NOT EXISTS idx_parcel_requests_scheduled ON parcel_requests(scheduled_at) WHERE scheduled_at IS NOT NULL;

DROP TRIGGER IF EXISTS trg_parcel_requests_updated_at ON parcel_requests;
CREATE TRIGGER trg_parcel_requests_updated_at
  BEFORE UPDATE ON parcel_requests
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE parcel_requests ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- PAYMENTS
-- =============================================================

CREATE TYPE payment_processor AS ENUM ('cash', 'stripe', 'card', 'wallet');
CREATE TYPE payment_status AS ENUM ('pending', 'processing', 'succeeded', 'failed', 'refunded');

CREATE TABLE IF NOT EXISTS payments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        UUID REFERENCES orders(id) ON DELETE CASCADE,
  user_id         UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  amount          NUMERIC(10,2) NOT NULL,
  currency        TEXT DEFAULT 'LKR',
  processor       payment_processor DEFAULT 'cash',
  status          payment_status DEFAULT 'pending',
  processor_id    TEXT, -- external gateway ID (Stripe intent, etc.)
  processor_data  JSONB,
  refund_amount   NUMERIC(10,2) DEFAULT 0,
  refund_reason   TEXT,
  paid_at         TIMESTAMPTZ,
  refunded_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payments_order ON payments(order_id);
CREATE INDEX IF NOT EXISTS idx_payments_user ON payments(user_id);
CREATE INDEX IF NOT EXISTS idx_payments_status ON payments(status);
CREATE INDEX IF NOT EXISTS idx_payments_processor ON payments(processor_id);

DROP TRIGGER IF EXISTS trg_payments_updated_at ON payments;
CREATE TRIGGER trg_payments_updated_at
  BEFORE UPDATE ON payments
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE payments ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- NOTIFICATIONS
-- =============================================================

CREATE TABLE IF NOT EXISTS notifications (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  title           TEXT NOT NULL,
  body            TEXT,
  type            TEXT, -- order_update, ride_update, promo, system
  reference_id    UUID, -- linked order, ride, etc.
  reference_type  TEXT, -- order, ride, parcel, etc.
  image_url       TEXT,
  data            JSONB,
  is_read         BOOLEAN DEFAULT false,
  read_at         TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_unread ON notifications(user_id, is_read) WHERE is_read = false;
CREATE INDEX IF NOT EXISTS idx_notifications_created ON notifications(created_at DESC);

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- ─── DEVICE TOKENS (push notifications) ──────────────────────

CREATE TABLE IF NOT EXISTS device_tokens (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  token           TEXT NOT NULL,
  platform        TEXT CHECK (platform IN ('ios', 'android', 'web')),
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, token)
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON device_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_device_tokens_active ON device_tokens(is_active) WHERE is_active = true;

DROP TRIGGER IF EXISTS trg_device_tokens_updated_at ON device_tokens;
CREATE TRIGGER trg_device_tokens_updated_at
  BEFORE UPDATE ON device_tokens
  FOR EACH ROW EXECUTE FUNCTION trigger_updated_at();

ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY;

-- =============================================================
-- ROW LEVEL SECURITY POLICIES
-- =============================================================

-- ─── PROFILES ─────────────────────────────────────────────────

CREATE POLICY "Users can view own profile"
  ON profiles FOR SELECT
  USING (auth.uid()::text = user_id);

CREATE POLICY "Users can insert own profile"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid()::text = user_id);

CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE
  USING (auth.uid()::text = user_id);

-- ─── ROLES ────────────────────────────────────────────────────

CREATE POLICY "Anyone can view roles"
  ON roles FOR SELECT
  USING (true);

-- ─── USER ROLES ──────────────────────────────────────────────

CREATE POLICY "Users can view own roles"
  ON user_roles FOR SELECT
  USING (auth.uid()::text = user_id);

CREATE POLICY "Admins can manage roles"
  ON user_roles FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM user_roles ur
      JOIN roles r ON r.id = ur.role_id
      WHERE ur.user_id = auth.uid() AND r.name = 'admin'
    )
  );

-- ─── ADDRESSES ───────────────────────────────────────────────

CREATE POLICY "Users manage own addresses"
  ON addresses FOR ALL
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

-- ─── MERCHANTS ────────────────────────────────────────────────

CREATE POLICY "Anyone can view active merchants"
  ON merchants FOR SELECT
  USING (is_active = true OR owner_id = auth.uid());

CREATE POLICY "Merchant owners update own"
  ON merchants FOR UPDATE
  USING (owner_id = auth.uid());

CREATE POLICY "Merchant owners insert"
  ON merchants FOR INSERT
  WITH CHECK (owner_id = auth.uid());

-- ─── MERCHANT STAFF ──────────────────────────────────────────

CREATE POLICY "Merchant staff can view"
  ON merchant_staff FOR SELECT
  USING (
    auth.uid()::text = user_id OR
    merchant_id IN (SELECT merchant_id FROM merchant_staff WHERE user_id = auth.uid())
  );

CREATE POLICY "Merchant owners manage staff"
  ON merchant_staff FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM merchant_staff ms
      WHERE ms.merchant_id = merchant_staff.merchant_id
        AND ms.user_id = auth.uid()
        AND ms.role IN ('owner', 'manager')
    )
  );

-- ─── CATEGORIES ──────────────────────────────────────────────

CREATE POLICY "Anyone can view categories"
  ON categories FOR SELECT
  USING (true);

CREATE POLICY "Merchant owners manage categories"
  ON categories FOR ALL
  USING (
    merchant_id IN (SELECT merchant_id FROM merchant_staff WHERE user_id = auth.uid())
  );

-- ─── PRODUCTS ────────────────────────────────────────────────

CREATE POLICY "Anyone can view active products"
  ON products FOR SELECT
  USING (is_active = true OR merchant_id IN (
    SELECT merchant_id FROM merchant_staff WHERE user_id = auth.uid()
  ));

CREATE POLICY "Merchant staff manage products"
  ON products FOR ALL
  USING (
    merchant_id IN (SELECT merchant_id FROM merchant_staff WHERE user_id = auth.uid())
  );

-- ─── PRODUCT IMAGES ──────────────────────────────────────────

CREATE POLICY "Anyone can view product images"
  ON product_images FOR SELECT
  USING (true);

CREATE POLICY "Merchant staff manage images"
  ON product_images FOR ALL
  USING (
    product_id IN (
      SELECT p.id FROM products p
      JOIN merchant_staff ms ON ms.merchant_id = p.merchant_id
      WHERE ms.user_id = auth.uid()
    )
  );

-- ─── ORDERS ──────────────────────────────────────────────────

CREATE POLICY "Users view own orders"
  ON orders FOR SELECT
  USING (
    auth.uid()::text = user_id OR
    auth.uid() = driver_id OR
    merchant_id IN (SELECT merchant_id FROM merchant_staff WHERE user_id = auth.uid())
  );

CREATE POLICY "Users insert own orders"
  ON orders FOR INSERT
  WITH CHECK (auth.uid()::text = user_id);

CREATE POLICY "Users update own orders"
  ON orders FOR UPDATE
  USING (auth.uid()::text = user_id OR auth.uid() = driver_id);

CREATE POLICY "Merchant staff update orders"
  ON orders FOR UPDATE
  USING (
    merchant_id IN (SELECT merchant_id FROM merchant_staff WHERE user_id = auth.uid())
  );

-- ─── ORDER ITEMS ─────────────────────────────────────────────

CREATE POLICY "View order items"
  ON order_items FOR SELECT
  USING (
    order_id IN (SELECT id FROM orders WHERE
      user_id = auth.uid() OR
      driver_id = auth.uid() OR
      merchant_id IN (SELECT merchant_id FROM merchant_staff WHERE user_id = auth.uid())
    )
  );

CREATE POLICY "Insert order items"
  ON order_items FOR INSERT
  WITH CHECK (
    order_id IN (SELECT id FROM orders WHERE user_id = auth.uid())
  );

-- ─── DRIVERS ──────────────────────────────────────────────────

CREATE POLICY "Anyone can view drivers"
  ON drivers FOR SELECT
  USING (true);

CREATE POLICY "Drivers update own profile"
  ON drivers FOR UPDATE
  USING (auth.uid()::text = user_id);

-- ─── DRIVER LOCATIONS ────────────────────────────────────────

CREATE POLICY "Drivers insert own location"
  ON driver_locations FOR INSERT
  WITH CHECK (
    driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
  );

CREATE POLICY "Anyone can view driver locations"
  ON driver_locations FOR SELECT
  USING (true);

-- ─── DRIVER JOBS ─────────────────────────────────────────────

CREATE POLICY "Drivers view own jobs"
  ON driver_jobs FOR SELECT
  USING (driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid()));

CREATE POLICY "Drivers update own jobs"
  ON driver_jobs FOR UPDATE
  USING (driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid()));

CREATE POLICY "Users view jobs for own orders"
  ON driver_jobs FOR SELECT
  USING (
    order_id IN (SELECT id FROM orders WHERE user_id = auth.uid())
  );

-- ─── RIDE REQUESTS ───────────────────────────────────────────

CREATE POLICY "Users manage own ride requests"
  ON ride_requests FOR ALL
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

CREATE POLICY "Drivers view available rides"
  ON ride_requests FOR SELECT
  USING (status = 'searching' OR driver_id IN (
    SELECT id FROM drivers WHERE user_id = auth.uid()
  ));

CREATE POLICY "Drivers accept ride requests"
  ON ride_requests FOR UPDATE
  USING (
    status = 'searching' AND
    auth.uid() IN (SELECT user_id FROM drivers WHERE is_online = true)
  );

-- ─── PARCEL REQUESTS ─────────────────────────────────────────

CREATE POLICY "Users manage own parcel requests"
  ON parcel_requests FOR ALL
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

CREATE POLICY "Drivers view and update parcel requests"
  ON parcel_requests FOR SELECT
  USING (
    status IN ('pending', 'picked_up', 'in_transit', 'out_for_delivery')
  );

-- ─── PAYMENTS ────────────────────────────────────────────────

CREATE POLICY "Users view own payments"
  ON payments FOR SELECT
  USING (auth.uid()::text = user_id);

CREATE POLICY "Users insert own payments"
  ON payments FOR INSERT
  WITH CHECK (auth.uid()::text = user_id);

-- ─── NOTIFICATIONS ───────────────────────────────────────────

CREATE POLICY "Users manage own notifications"
  ON notifications FOR ALL
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

-- ─── DEVICE TOKENS ───────────────────────────────────────────

CREATE POLICY "Users manage own device tokens"
  ON device_tokens FOR ALL
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);

-- =============================================================
-- STORAGE BUCKETS
-- =============================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('product-images', 'product-images', true, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp']),
  ('profile-images', 'profile-images', true, 2097152, ARRAY['image/jpeg', 'image/png', 'image/webp']),
  ('parcel-images', 'parcel-images', true, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ─── STORAGE POLICIES ────────────────────────────────────────

-- Product images: anyone can view, merchants can upload/delete
CREATE POLICY "Anyone can view product images"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'product-images');

CREATE POLICY "Merchant staff can upload product images"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'product-images' AND
    auth.role() = 'authenticated'
  );

CREATE POLICY "Merchant staff can delete own product images"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'product-images' AND
    auth.role() = 'authenticated'
  );

-- Profile images: anyone can view, user can upload own
CREATE POLICY "Anyone can view profile images"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'profile-images');

CREATE POLICY "Users can upload own profile images"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'profile-images' AND
    auth.role() = 'authenticated' AND
    (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "Users can delete own profile images"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'profile-images' AND
    (storage.foldername(name))[1] = auth.uid()::text
  );

-- Parcel images: anyone can view, user can upload
CREATE POLICY "Anyone can view parcel images"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'parcel-images');

CREATE POLICY "Users can upload parcel images"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'parcel-images' AND
    auth.role() = 'authenticated'
  );

CREATE POLICY "Users can delete own parcel images"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'parcel-images' AND
    auth.role() = 'authenticated'
  );

-- =============================================================
-- HELPER VIEWS
-- =============================================================

-- Active ride/order for a user (for Live Activity card)
CREATE OR REPLACE VIEW active_user_orders AS
SELECT
  o.id,
  o.user_id,
  o.order_type,
  o.status,
  o.total,
  o.created_at,
  m.name AS merchant_name,
  m.logo_url AS merchant_logo,
  d.full_name AS driver_name,
  d.vehicle_number,
  rr.ride_type,
  rr.pickup_name,
  rr.dropoff_name,
  rr.distance_km,
  rr.duration_min AS eta_min
FROM orders o
LEFT JOIN merchants m ON m.id = o.merchant_id
LEFT JOIN drivers d ON d.id = o.driver_id
LEFT JOIN ride_requests rr ON rr.id = o.reference_id AND o.order_type = 'ride'
WHERE o.status NOT IN ('delivered', 'cancelled')
ORDER BY o.created_at DESC;

-- Merchant dashboard: order stats
CREATE OR REPLACE VIEW merchant_order_stats AS
SELECT
  m.id AS merchant_id,
  m.name AS merchant_name,
  COUNT(o.id) FILTER (WHERE o.status = 'pending') AS pending_count,
  COUNT(o.id) FILTER (WHERE o.status = 'preparing') AS preparing_count,
  COUNT(o.id) FILTER (WHERE o.status = 'on_the_way') AS delivery_count,
  COUNT(o.id) FILTER (WHERE o.status = 'delivered' AND o.created_at >= now() - interval '7 days') AS weekly_delivered,
  COALESCE(SUM(o.total) FILTER (WHERE o.status = 'delivered' AND o.created_at >= now() - interval '7 days'), 0) AS weekly_revenue
FROM merchants m
LEFT JOIN orders o ON o.merchant_id = m.id
GROUP BY m.id, m.name;

-- =============================================================
-- RELATIONSHIP SUMMARY
-- =============================================================
/*
profiles (1:1 with auth.users)
  ├── addresses (1:N) — user can have multiple saved addresses
  ├── user_roles (N:M) — users can have multiple roles (customer, merchant, driver)
  │   └── roles — available role definitions
  ├── orders:user_id (1:N) — orders placed by user
  ├── ride_requests:user_id (1:N)
  ├── parcel_requests:user_id (1:N)
  ├── notifications:user_id (1:N)
  └── device_tokens:user_id (1:N)

merchants — owned by auth.users via owner_id
  ├── merchant_staff (1:N) — staff members of a merchant
  ├── categories (1:N) — menu/grocery categories
  │   └── products (1:N) — items in that category
  │       └── product_images (1:N) — photos of each product
  └── orders:merchant_id (1:N) — orders received

drivers — linked to auth.users via user_id
  ├── driver_locations (1:N) — real-time GPS breadcrumbs
  ├── driver_jobs (1:N) — delivery/ride assignments
  │   └── orders:driver_id (1:N)
  ├── ride_requests:driver_id (1:N)
  └── parcel_requests:driver_id (1:N)

orders — polymorphic order table
  ├── order_items (1:N) — line items
  ├── payments (1:N) — payment transactions
  ├── driver_jobs:order_id (1:1) — driver assignment
  ├── ride_requests:reference_id — optional link for ride orders
  └── parcel_requests:reference_id — optional link for parcel orders

ride_requests — standalone ride booking
  └── orders:reference_id (optional link)

parcel_requests — standalone parcel delivery
  └── orders:reference_id (optional link)
*/
