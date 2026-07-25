-- =============================================================
-- P1 MERCHANT OPERATIONS BACKEND
-- =============================================================
-- Adds production-ready operation management columns to the
-- application-active merchant table (public."Restaurants") and
-- the future-schema table (public.merchants).
--
-- Does NOT rename tables, drop columns, or perform dual-schema
-- migration. Preserves all existing P0 security policies.
-- =============================================================
-- SAFE TO RE-RUN: uses IF NOT EXISTS / OR REPLACE / DROP IF EXISTS
-- =============================================================

-- =============================================================
-- 1. ADD COLUMNS TO LEGACY TABLE (application-active)
-- =============================================================

DO $$
BEGIN
  -- Busy mode
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Restaurants' AND column_name = 'busy_mode'
  ) THEN
    ALTER TABLE public."Restaurants" ADD COLUMN busy_mode BOOLEAN NOT NULL DEFAULT false;
  END IF;

  -- Holiday mode
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Restaurants' AND column_name = 'holiday_mode'
  ) THEN
    ALTER TABLE public."Restaurants" ADD COLUMN holiday_mode BOOLEAN NOT NULL DEFAULT false;
  END IF;

  -- Holiday start
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Restaurants' AND column_name = 'holiday_start'
  ) THEN
    ALTER TABLE public."Restaurants" ADD COLUMN holiday_start TIMESTAMPTZ;
  END IF;

  -- Holiday end
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Restaurants' AND column_name = 'holiday_end'
  ) THEN
    ALTER TABLE public."Restaurants" ADD COLUMN holiday_end TIMESTAMPTZ;
  END IF;

  -- Holiday message (optional)
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Restaurants' AND column_name = 'holiday_message'
  ) THEN
    ALTER TABLE public."Restaurants" ADD COLUMN holiday_message TEXT;
  END IF;

  -- Auto accept orders
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Restaurants' AND column_name = 'auto_accept_orders'
  ) THEN
    ALTER TABLE public."Restaurants" ADD COLUMN auto_accept_orders BOOLEAN NOT NULL DEFAULT false;
  END IF;

  -- Estimated preparation minutes
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Restaurants' AND column_name = 'estimated_preparation_minutes'
  ) THEN
    ALTER TABLE public."Restaurants" ADD COLUMN estimated_preparation_minutes INTEGER NOT NULL DEFAULT 30;
  END IF;

  -- Business hours (weekly JSON schedule)
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Restaurants' AND column_name = 'business_hours'
  ) THEN
    ALTER TABLE public."Restaurants" ADD COLUMN business_hours JSONB NOT NULL DEFAULT '{
      "monday":    {"enabled": true, "open": "09:00", "close": "22:00"},
      "tuesday":   {"enabled": true, "open": "09:00", "close": "22:00"},
      "wednesday": {"enabled": true, "open": "09:00", "close": "22:00"},
      "thursday":  {"enabled": true, "open": "09:00", "close": "22:00"},
      "friday":    {"enabled": true, "open": "09:00", "close": "22:00"},
      "saturday":  {"enabled": true, "open": "09:00", "close": "22:00"},
      "sunday":    {"enabled": true, "open": "09:00", "close": "22:00"}
    }'::jsonb;
  END IF;

  -- Operations updated at
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Restaurants' AND column_name = 'operations_updated_at'
  ) THEN
    ALTER TABLE public."Restaurants" ADD COLUMN operations_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
  END IF;
END $$;

-- =============================================================
-- 2. ADD COLUMNS TO FUTURE-SCHEMA TABLE (for consistency)
-- =============================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'merchants') THEN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'merchants' AND column_name = 'busy_mode') THEN
      ALTER TABLE public.merchants ADD COLUMN busy_mode BOOLEAN NOT NULL DEFAULT false;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'merchants' AND column_name = 'holiday_mode') THEN
      ALTER TABLE public.merchants ADD COLUMN holiday_mode BOOLEAN NOT NULL DEFAULT false;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'merchants' AND column_name = 'holiday_start') THEN
      ALTER TABLE public.merchants ADD COLUMN holiday_start TIMESTAMPTZ;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'merchants' AND column_name = 'holiday_end') THEN
      ALTER TABLE public.merchants ADD COLUMN holiday_end TIMESTAMPTZ;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'merchants' AND column_name = 'holiday_message') THEN
      ALTER TABLE public.merchants ADD COLUMN holiday_message TEXT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'merchants' AND column_name = 'auto_accept_orders') THEN
      ALTER TABLE public.merchants ADD COLUMN auto_accept_orders BOOLEAN NOT NULL DEFAULT false;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'merchants' AND column_name = 'estimated_preparation_minutes') THEN
      ALTER TABLE public.merchants ADD COLUMN estimated_preparation_minutes INTEGER NOT NULL DEFAULT 30;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'merchants' AND column_name = 'business_hours') THEN
      ALTER TABLE public.merchants ADD COLUMN business_hours JSONB NOT NULL DEFAULT '{}'::jsonb;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'merchants' AND column_name = 'operations_updated_at') THEN
      ALTER TABLE public.merchants ADD COLUMN operations_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
    END IF;
  END IF;
END $$;

-- =============================================================
-- 3. CONSTRAINTS
-- =============================================================

-- Estimated preparation time: 5-240 minutes
ALTER TABLE public."Restaurants" DROP CONSTRAINT IF EXISTS ck_restaurants_prep_time;
ALTER TABLE public."Restaurants" ADD CONSTRAINT ck_restaurants_prep_time
  CHECK (estimated_preparation_minutes >= 5 AND estimated_preparation_minutes <= 240);

-- Holiday end must be after start (when both are set)
ALTER TABLE public."Restaurants" DROP CONSTRAINT IF EXISTS ck_restaurants_holiday_range;
ALTER TABLE public."Restaurants" ADD CONSTRAINT ck_restaurants_holiday_range
  CHECK (
    holiday_start IS NULL OR
    holiday_end IS NULL OR
    holiday_end > holiday_start
  );

-- Future table constraints
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'merchants') THEN
    ALTER TABLE public.merchants DROP CONSTRAINT IF EXISTS ck_merchants_prep_time;
    ALTER TABLE public.merchants ADD CONSTRAINT ck_merchants_prep_time
      CHECK (estimated_preparation_minutes >= 5 AND estimated_preparation_minutes <= 240);
    ALTER TABLE public.merchants DROP CONSTRAINT IF EXISTS ck_merchants_holiday_range;
    ALTER TABLE public.merchants ADD CONSTRAINT ck_merchants_holiday_range
      CHECK (holiday_start IS NULL OR holiday_end IS NULL OR holiday_end > holiday_start);
  END IF;
END $$;

-- =============================================================
-- 4. UPDATED-AT TRIGGER
-- =============================================================

CREATE OR REPLACE FUNCTION public.trigger_operations_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.operations_updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_restaurants_operations_updated_at ON public."Restaurants";
CREATE TRIGGER trg_restaurants_operations_updated_at
  BEFORE UPDATE OF
    busy_mode, holiday_mode, holiday_start, holiday_end, holiday_message,
    auto_accept_orders, estimated_preparation_minutes, business_hours
  ON public."Restaurants"
  FOR EACH ROW
  EXECUTE FUNCTION public.trigger_operations_updated_at();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'merchants') THEN
    DROP TRIGGER IF EXISTS trg_merchants_operations_updated_at ON public.merchants;
    CREATE TRIGGER trg_merchants_operations_updated_at
      BEFORE UPDATE OF
        busy_mode, holiday_mode, holiday_start, holiday_end, holiday_message,
        auto_accept_orders, estimated_preparation_minutes, business_hours
      ON public.merchants
      FOR EACH ROW
      EXECUTE FUNCTION public.trigger_operations_updated_at();
  END IF;
END $$;

-- =============================================================
-- 5. RLS POLICIES FOR NEW COLUMNS
-- =============================================================
-- Restaurants already has RLS enabled with owner-scoped policies
-- from the P0 security migration. The new columns are covered
-- by the existing UPDATE/DELETE policies which check owner_id.
-- No additional policies needed.

-- =============================================================
-- 6. BACKFILL EXISTING DATA
-- =============================================================

-- Derive estimated_preparation_minutes from delivery_time text
UPDATE public."Restaurants"
SET estimated_preparation_minutes =
  CASE
    WHEN delivery_time ~ '^\d+$' THEN GREATEST(5, LEAST(240, delivery_time::INTEGER))
    WHEN delivery_time ~ '^\d+' THEN GREATEST(5, LEAST(240, (regexp_match(delivery_time, '(\d+)'))[1]::INTEGER))
    ELSE 30
  END
WHERE estimated_preparation_minutes = 30
  AND delivery_time IS NOT NULL
  AND delivery_time != '';

-- Generate business_hours from legacy opens_at/closes_at if those columns exist
-- (Note: Restaurants table in the legacy schema does NOT have opens_at/closes_at,
--  so this only applies to the merchants table.)

DO $$
DECLARE
  default_hours JSONB := '{
    "monday":    {"enabled": true, "open": "09:00", "close": "22:00"},
    "tuesday":   {"enabled": true, "open": "09:00", "close": "22:00"},
    "wednesday": {"enabled": true, "open": "09:00", "close": "22:00"},
    "thursday":  {"enabled": true, "open": "09:00", "close": "22:00"},
    "friday":    {"enabled": true, "open": "09:00", "close": "22:00"},
    "saturday":  {"enabled": true, "open": "09:00", "close": "22:00"},
    "sunday":    {"enabled": true, "open": "09:00", "close": "22:00"}
  }'::jsonb;
BEGIN
  -- Set default business_hours for any row still using the default empty JSON
  UPDATE public."Restaurants"
  SET business_hours = default_hours
  WHERE business_hours = '{}'::jsonb OR business_hours IS NULL OR business_hours = '{
      "monday":    {"enabled": true, "open": "09:00", "close": "22:00"},
      "tuesday":   {"enabled": true, "open": "09:00", "close": "22:00"},
      "wednesday": {"enabled": true, "open": "09:00", "close": "22:00"},
      "thursday":  {"enabled": true, "open": "09:00", "close": "22:00"},
      "friday":    {"enabled": true, "open": "09:00", "close": "22:00"},
      "saturday":  {"enabled": true, "open": "09:00", "close": "22:00"},
      "sunday":    {"enabled": true, "open": "09:00", "close": "22:00"}
    }'::jsonb;
END $$;

-- =============================================================
-- 7. INDEXES
-- =============================================================

CREATE INDEX IF NOT EXISTS idx_restaurants_owner_id ON public."Restaurants"(owner_id);
CREATE INDEX IF NOT EXISTS idx_restaurants_busy_mode ON public."Restaurants"(busy_mode) WHERE busy_mode = true;
CREATE INDEX IF NOT EXISTS idx_restaurants_holiday_mode ON public."Restaurants"(holiday_mode) WHERE holiday_mode = true;

-- =============================================================
-- 8. RPC: UPDATE MERCHANT OPERATIONS
-- =============================================================

CREATE OR REPLACE FUNCTION public.update_merchant_operations(
  p_restaurant_id TEXT,
  p_busy_mode BOOLEAN DEFAULT NULL,
  p_holiday_mode BOOLEAN DEFAULT NULL,
  p_holiday_start TIMESTAMPTZ DEFAULT NULL,
  p_holiday_end TIMESTAMPTZ DEFAULT NULL,
  p_auto_accept_orders BOOLEAN DEFAULT NULL,
  p_estimated_preparation_minutes INTEGER DEFAULT NULL,
  p_business_hours JSONB DEFAULT NULL,
  p_holiday_message TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_owner_id TEXT;
  v_result JSONB;
BEGIN
  -- Authenticate
  v_owner_id := auth.uid()::text;
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- Verify ownership
  IF NOT EXISTS (
    SELECT 1 FROM public."Restaurants"
    WHERE id = p_restaurant_id AND owner_id = v_owner_id
  ) THEN
    RAISE EXCEPTION 'Merchant not found or access denied';
  END IF;

  -- Validate estimated_preparation_minutes
  IF p_estimated_preparation_minutes IS NOT NULL THEN
    IF p_estimated_preparation_minutes < 5 OR p_estimated_preparation_minutes > 240 THEN
      RAISE EXCEPTION 'Estimated preparation time must be between 5 and 240 minutes';
    END IF;
  END IF;

  -- Validate business_hours JSON structure
  IF p_business_hours IS NOT NULL THEN
    IF NOT (
      p_business_hours ? 'monday' AND
      p_business_hours ? 'tuesday' AND
      p_business_hours ? 'wednesday' AND
      p_business_hours ? 'thursday' AND
      p_business_hours ? 'friday' AND
      p_business_hours ? 'saturday' AND
      p_business_hours ? 'sunday'
    ) THEN
      RAISE EXCEPTION 'business_hours must contain all 7 days';
    END IF;
  END IF;

  -- Validate holiday end > start
  IF p_holiday_mode = true AND p_holiday_start IS NOT NULL AND p_holiday_end IS NOT NULL THEN
    IF p_holiday_end <= p_holiday_start THEN
      RAISE EXCEPTION 'Holiday end must be after start';
    END IF;
  END IF;

  -- Update only provided fields
  UPDATE public."Restaurants" SET
    busy_mode                      = COALESCE(p_busy_mode, busy_mode),
    holiday_mode                   = COALESCE(p_holiday_mode, holiday_mode),
    holiday_start                  = COALESCE(p_holiday_start, holiday_start),
    holiday_end                    = COALESCE(p_holiday_end, holiday_end),
    holiday_message                = COALESCE(p_holiday_message, holiday_message),
    auto_accept_orders             = COALESCE(p_auto_accept_orders, auto_accept_orders),
    estimated_preparation_minutes  = COALESCE(p_estimated_preparation_minutes, estimated_preparation_minutes),
    business_hours                 = COALESCE(p_business_hours, business_hours)
  WHERE id = p_restaurant_id AND owner_id = v_owner_id;

  -- Return updated record
  SELECT row_to_json(r)::jsonb INTO v_result
  FROM (
    SELECT
      id, owner_id, busy_mode, holiday_mode, holiday_start, holiday_end,
      holiday_message, auto_accept_orders, estimated_preparation_minutes,
      business_hours, operations_updated_at
    FROM public."Restaurants"
    WHERE id = p_restaurant_id AND owner_id = v_owner_id
  ) r;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_merchant_operations FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_merchant_operations TO authenticated;

-- =============================================================
-- 9. RPC: GET MERCHANT ACCEPTING STATUS
-- =============================================================

CREATE OR REPLACE FUNCTION public.get_merchant_accepting_status(
  p_restaurant_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_merchant RECORD;
  v_now TIMESTAMPTZ := now();
  v_current_day TEXT;
  v_today_schedule JSONB;
  v_is_accepting BOOLEAN;
  v_reason TEXT;
  v_within_hours BOOLEAN := false;
  v_current_time TEXT;
BEGIN
  SELECT * INTO v_merchant
  FROM public."Restaurants"
  WHERE id = p_restaurant_id;

  IF v_merchant IS NULL THEN
    RETURN jsonb_build_object('error', 'Merchant not found');
  END IF;

  -- Holiday check
  IF v_merchant.holiday_mode = true THEN
    IF v_merchant.holiday_start IS NOT NULL AND v_merchant.holiday_end IS NOT NULL THEN
      IF v_now >= v_merchant.holiday_start AND v_now <= v_merchant.holiday_end THEN
        RETURN jsonb_build_object(
          'is_accepting_orders', false,
          'reason', 'on_holiday',
          'holiday_mode', true,
          'busy_mode', v_merchant.busy_mode,
          'within_business_hours', false,
          'estimated_preparation_minutes', v_merchant.estimated_preparation_minutes,
          'holiday_message', v_merchant.holiday_message
        );
      END IF;
    ELSE
      -- Holiday mode on but no dates set — treat as indefinite
      RETURN jsonb_build_object(
        'is_accepting_orders', false,
        'reason', 'on_holiday',
        'holiday_mode', true,
        'busy_mode', v_merchant.busy_mode,
        'within_business_hours', false,
        'estimated_preparation_minutes', v_merchant.estimated_preparation_minutes
      );
    END IF;
  END IF;

  -- Manual open/closed check (is_open = false means closed)
  IF v_merchant.is_open = false THEN
    RETURN jsonb_build_object(
      'is_accepting_orders', false,
      'reason', 'manually_closed',
      'holiday_mode', false,
      'busy_mode', v_merchant.busy_mode,
      'within_business_hours', false,
      'estimated_preparation_minutes', v_merchant.estimated_preparation_minutes
    );
  END IF;

  -- Business hours check
  v_current_day := lower(trim(to_char(v_now, 'Day')));
  v_today_schedule := v_merchant.business_hours -> v_current_day;

  IF v_today_schedule IS NOT NULL AND (v_today_schedule->>'enabled')::boolean = true THEN
    v_current_time := to_char(v_now, 'HH24:MI');
    -- Compare times as strings (HH:MI format sorts lexicographically)
    -- Support overnight schedules: if close < open, treat as next day
    IF (v_today_schedule->>'close')::text < (v_today_schedule->>'open')::text THEN
      -- Overnight schedule (e.g., 18:00 to 02:00)
      v_within_hours := v_current_time >= (v_today_schedule->>'open')::text
                     OR v_current_time <= (v_today_schedule->>'close')::text;
    ELSE
      v_within_hours := v_current_time >= (v_today_schedule->>'open')::text
                     AND v_current_time <= (v_today_schedule->>'close')::text;
    END IF;
  END IF;

  -- Determine final status
  v_is_accepting := v_within_hours;
  v_reason := CASE
    WHEN NOT v_within_hours THEN 'outside_business_hours'
    ELSE 'accepting_orders'
  END;

  RETURN jsonb_build_object(
    'is_accepting_orders', v_is_accepting,
    'reason', v_reason,
    'holiday_mode', false,
    'busy_mode', v_merchant.busy_mode,
    'within_business_hours', v_within_hours,
    'estimated_preparation_minutes', v_merchant.estimated_preparation_minutes
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_merchant_accepting_status FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_accepting_status TO authenticated;

-- =============================================================
-- 10. DOCUMENTATION
-- =============================================================
/*
FIELD DESCRIPTIONS (public."Restaurants"):

  busy_mode                      BOOLEAN  – Merchant indicates high volume.
                                            Orders are still accepted but
                                            preparation may take longer.
  holiday_mode                   BOOLEAN  – Store is closed for holiday.
                                            When true and holiday_start/end
                                            are set, orders are rejected
                                            during that period.
  holiday_start                  TIMESTAMPTZ – Holiday period start.
  holiday_end                    TIMESTAMPTZ – Holiday period end.
  holiday_message                TEXT     – Optional public message shown
                                            to customers during holiday.
  auto_accept_orders             BOOLEAN  – If true, new pending orders
                                            are automatically accepted.
                                            NOTE: Order workflow integration
                                            is pending. This field is stored
                                            but not yet consumed by the
                                            order-creation pipeline.
  estimated_preparation_minutes  INTEGER  – Typical minutes to prepare
                                            an order. Range: 5-240.
  business_hours                 JSONB    – Weekly schedule. See format
                                            below. All 7 days required.
  operations_updated_at          TIMESTAMPTZ – Auto-updated when any
                                            operation field changes.

BUSINESS HOURS JSON FORMAT:
  {
    "monday":    {"enabled": true,  "open": "09:00", "close": "22:00"},
    "tuesday":   {"enabled": true,  "open": "09:00", "close": "22:00"},
    ...
    "sunday":    {"enabled": true,  "open": "09:00", "close": "22:00"}
  }
  - All 7 days must be present.
  - enabled: boolean. When false, the store is closed that day.
  - open/close: HH:MI format (24-hour).
  - Overnight schedules supported (close < open).

HOLIDAY MODE BEHAVIOUR:
  - When holiday_mode = true AND current time is within holiday_start..end:
    store is not accepting orders.
  - When holiday_mode = true but holiday_start/end are NULL:
    treated as indefinite holiday (store not accepting orders).

BUSY MODE BEHAVIOUR:
  - Store remains open and accepting orders.
  - Estimated preparation time may be longer.
  - Customers see a "busy" indicator.

AUTO-ACCEPT BEHAVIOUR:
  - Field is stored for future order-workflow integration.
  - Current order creation pipeline does NOT read this field.
  - Integration pending: requires modification of create_customer_order
    or a trigger on Orders INSERT to check merchant.auto_accept_orders
    and auto-transition status from 'pending' to 'accepted'.

APPLICATION-ACTIVE TABLE:
  - Ale-Merchant reads/writes public."Restaurants" (legacy quoted table).
  - The lowercase public.merchants table is part of the intended future
    schema and is updated here for consistency but is NOT yet read by
    any application.

DUAL-SCHEMA CONSIDERATIONS:
  When the dual-schema migration is eventually performed, the operation
  columns from this migration on both tables will be merged. The
  business_hours JSON format is identical across both tables to
  simplify migration.
*/
