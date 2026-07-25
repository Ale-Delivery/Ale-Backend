-- ============================================================
-- SAFE PRODUCTION MIGRATION FOR SAVED ADDRESSES
-- This migration does not drop existing tables or data.
-- ============================================================

create extension if not exists pgcrypto;

alter table public."Saved_Addresses"
add column if not exists latitude double precision,
add column if not exists longitude double precision,
add column if not exists is_default boolean not null default false,
add column if not exists updated_at timestamptz not null default now();

alter table public."Saved_Addresses"
alter column phone set not null;

create index if not exists
idx_saved_addresses_user_id
on public."Saved_Addresses"(user_id);

create index if not exists
idx_saved_addresses_user_updated
on public."Saved_Addresses"(user_id, updated_at desc);

create unique index if not exists
idx_saved_addresses_one_default_per_user
on public."Saved_Addresses"(user_id)
where is_default = true;

-- Ensure only one existing default per user.
with ranked_defaults as (
  select
    id,
    row_number() over (
      partition by user_id
      order by updated_at desc, created_at desc
    ) as row_number
  from public."Saved_Addresses"
  where is_default = true
)
update public."Saved_Addresses"
set is_default = false
where id in (
  select id
  from ranked_defaults
  where row_number > 1
);

-- Make the first valid address default for users who do not have one.
with users_without_default as (
  select distinct user_id
  from public."Saved_Addresses"
  except
  select distinct user_id
  from public."Saved_Addresses"
  where is_default = true
),
first_addresses as (
  select distinct on (address.user_id)
    address.id
  from public."Saved_Addresses" address
  join users_without_default missing
    on missing.user_id = address.user_id
  order by
    address.user_id,
    address.created_at asc
)
update public."Saved_Addresses"
set is_default = true
where id in (
  select id from first_addresses
);

-- ============================================================
-- UPDATED_AT TRIGGER
-- ============================================================

create or replace function
public.set_saved_address_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists
trigger_saved_address_updated_at
on public."Saved_Addresses";

create trigger
trigger_saved_address_updated_at
before update
on public."Saved_Addresses"
for each row
execute function
public.set_saved_address_updated_at();

-- ============================================================
-- SECURE RLS POLICIES
-- ============================================================

alter table public."Saved_Addresses"
enable row level security;

drop policy if exists
"Users manage own addresses"
on public."Saved_Addresses";

drop policy if exists
"Users read own saved addresses"
on public."Saved_Addresses";

drop policy if exists
"Users create own saved addresses"
on public."Saved_Addresses";

drop policy if exists
"Users update own saved addresses"
on public."Saved_Addresses";

drop policy if exists
"Users delete own saved addresses"
on public."Saved_Addresses";

create policy
"Users read own saved addresses"
on public."Saved_Addresses"
for select
to authenticated
using (
  user_id = auth.uid()::text
);

create policy
"Users create own saved addresses"
on public."Saved_Addresses"
for insert
to authenticated
with check (
  user_id = auth.uid()::text
);

create policy
"Users update own saved addresses"
on public."Saved_Addresses"
for update
to authenticated
using (
  user_id = auth.uid()::text
)
with check (
  user_id = auth.uid()::text
);

create policy
"Users delete own saved addresses"
on public."Saved_Addresses"
for delete
to authenticated
using (
  user_id = auth.uid()::text
);

-- ============================================================
-- SAVE ADDRESS RPC
-- Atomically creates or updates an address and manages default.
-- ============================================================

create or replace function
public.save_saved_address(
  p_address_id uuid,
  p_label text,
  p_address text,
  p_phone text,
  p_latitude double precision,
  p_longitude double precision,
  p_is_default boolean
)
returns setof public."Saved_Addresses"
language plpgsql
security invoker
set search_path = public
as $$
declare
  current_user_id text;
  target_id uuid;
  should_be_default boolean;
  existing_default boolean;
begin
  current_user_id := auth.uid()::text;

  if current_user_id is null then
    raise exception 'Authentication required';
  end if;

  if trim(coalesce(p_address, '')) = '' then
    raise exception 'Delivery address is required';
  end if;

  if trim(coalesce(p_phone, '')) = '' then
    raise exception 'Recipient phone number is required';
  end if;

  if p_latitude is null
     or p_longitude is null
     or p_latitude < -90
     or p_latitude > 90
     or p_longitude < -180
     or p_longitude > 180
     or (p_latitude = 0 and p_longitude = 0)
  then
    raise exception 'Invalid location coordinates';
  end if;

  if exists (
    select 1
    from public."Saved_Addresses" address
    where address.user_id = current_user_id
      and (p_address_id is null or address.id <> p_address_id)
      and abs(address.latitude - p_latitude) < 0.001
      and abs(address.longitude - p_longitude) < 0.001
  ) then
    raise exception 'Duplicate address';
  end if;

  select exists (
    select 1
    from public."Saved_Addresses"
    where user_id = current_user_id
      and is_default = true
  )
  into existing_default;

  should_be_default :=
    coalesce(p_is_default, false)
    or not existing_default;

  if should_be_default then
    update public."Saved_Addresses"
    set is_default = false
    where user_id = current_user_id
      and is_default = true
      and (
        p_address_id is null
        or id <> p_address_id
      );
  end if;

  if p_address_id is null then
    insert into public."Saved_Addresses" (
      user_id,
      label,
      address,
      phone,
      latitude,
      longitude,
      is_default
    )
    values (
      current_user_id,
      coalesce(nullif(trim(p_label), ''), 'Home'),
      trim(p_address),
      trim(p_phone),
      p_latitude,
      p_longitude,
      should_be_default
    )
    returning id into target_id;
  else
    if not exists (
      select 1
      from public."Saved_Addresses"
      where id = p_address_id
        and user_id = current_user_id
    ) then
      raise exception 'Address not found';
    end if;

    update public."Saved_Addresses"
    set
      label = coalesce(
        nullif(trim(p_label), ''),
        'Home'
      ),
      address = trim(p_address),
      phone = trim(p_phone),
      latitude = p_latitude,
      longitude = p_longitude,
      is_default = case
        when should_be_default then true
        else is_default
      end
    where id = p_address_id
      and user_id = current_user_id
    returning id into target_id;
  end if;

  return query
  select *
  from public."Saved_Addresses"
  where id = target_id
    and user_id = current_user_id;
end;
$$;

-- ============================================================
-- SET DEFAULT RPC
-- ============================================================

create or replace function
public.set_default_saved_address(
  p_address_id uuid
)
returns setof public."Saved_Addresses"
language plpgsql
security invoker
set search_path = public
as $$
declare
  current_user_id text;
begin
  current_user_id := auth.uid()::text;

  if current_user_id is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public."Saved_Addresses"
    where id = p_address_id
      and user_id = current_user_id
  ) then
    raise exception 'Address not found';
  end if;

  update public."Saved_Addresses"
  set is_default = false
  where user_id = current_user_id
    and is_default = true;

  update public."Saved_Addresses"
  set is_default = true
  where id = p_address_id
    and user_id = current_user_id;

  return query
  select *
  from public."Saved_Addresses"
  where id = p_address_id
    and user_id = current_user_id;
end;
$$;

-- ============================================================
-- DELETE ADDRESS RPC
-- Automatically promotes another address when default is deleted.
-- ============================================================

create or replace function
public.delete_saved_address(
  p_address_id uuid
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  current_user_id text;
  deleted_was_default boolean;
  replacement_id uuid;
begin
  current_user_id := auth.uid()::text;

  if current_user_id is null then
    raise exception 'Authentication required';
  end if;

  select is_default
  into deleted_was_default
  from public."Saved_Addresses"
  where id = p_address_id
    and user_id = current_user_id;

  if not found then
    raise exception 'Address not found';
  end if;

  delete from public."Saved_Addresses"
  where id = p_address_id
    and user_id = current_user_id;

  if deleted_was_default then
    select id
    into replacement_id
    from public."Saved_Addresses"
    where user_id = current_user_id
    order by updated_at desc, created_at desc
    limit 1;

    if replacement_id is not null then
      update public."Saved_Addresses"
      set is_default = true
      where id = replacement_id
        and user_id = current_user_id;
    end if;
  end if;
end;
$$;

grant execute on function
public.save_saved_address(
  uuid,
  text,
  text,
  text,
  double precision,
  double precision,
  boolean
)
to authenticated;

grant execute on function
public.set_default_saved_address(uuid)
to authenticated;

grant execute on function
public.delete_saved_address(uuid)
to authenticated;