-- Fruit Shop: initial schema
-- Money is stored as bigint in the currency's smallest unit (AUD cents, VND dong).

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

create type public.app_role as enum ('owner', 'staff', 'driver', 'customer');
create type public.currency_code as enum ('AUD', 'VND');
create type public.lang_code as enum ('en', 'vi');
create type public.sell_unit as enum ('kg', 'box', 'each');
create type public.order_status as enum ('draft', 'confirmed', 'packed', 'out_for_delivery', 'completed', 'cancelled');
create type public.fulfilment_type as enum ('pickup', 'delivery');
create type public.invoice_status as enum ('unpaid', 'part_paid', 'paid', 'void');
create type public.payment_method as enum ('cash', 'card_in_shop', 'card_online', 'bank_transfer');
create type public.stock_reason as enum ('received', 'sold', 'wasted', 'adjusted', 'returned');
create type public.delivery_status as enum ('pending', 'assigned', 'out_for_delivery', 'delivered', 'failed');
create type public.payment_terms as enum ('pay_now', 'pay_on_delivery', 'on_account');

-- Currency follows language: English shows AUD, Vietnamese shows VND.
create function public.currency_for_lang(p_lang public.lang_code) returns public.currency_code
language sql immutable as $$
  select case p_lang when 'vi' then 'VND'::public.currency_code else 'AUD'::public.currency_code end;
$$;

-- ---------------------------------------------------------------------------
-- Shops
-- ---------------------------------------------------------------------------

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  country text not null check (country in ('AU', 'VN')),
  address text,
  phone text,
  is_active boolean not null default true
);

-- Flat delivery fee per shop and currency. Amounts to be confirmed by the owner.
create table public.delivery_fees (
  location_id uuid not null references public.locations (id) on delete cascade,
  currency public.currency_code not null,
  flat_fee bigint not null default 0 check (flat_fee >= 0),
  primary key (location_id, currency)
);

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------

-- One row per login account.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  role public.app_role not null default 'customer',
  full_name text not null default '',
  phone text,
  preferred_lang public.lang_code not null default 'en',
  location_id uuid references public.locations (id) on delete set null,  -- staff member's home shop
  created_at timestamptz not null default now()
);

-- A customer may have no login (walk-in or phone customers entered by staff).
create table public.customers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles (id) on delete set null,
  full_name text not null,
  business_name text,
  business_tax_id text,                  -- ABN in Australia, MST in Vietnam
  phone text,
  email text,
  preferred_lang public.lang_code not null default 'en',
  -- Set for regular business customers allowed to buy on account; null = must pay now or on delivery.
  account_terms_days int check (account_terms_days > 0),
  credit_limit bigint check (credit_limit >= 0),
  notes text,
  created_at timestamptz not null default now()
);

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers (id) on delete cascade,
  label text,
  line1 text not null,
  line2 text,
  city text not null,
  state text,
  postcode text,
  country text not null default 'AU',
  delivery_notes text,
  is_default boolean not null default false
);

-- ---------------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------------

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name_en text not null,
  name_vi text not null,
  sort_order int not null default 0
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  sku text unique,
  category_id uuid references public.categories (id) on delete set null,
  name_en text not null,
  name_vi text not null,
  description_en text,
  description_vi text,
  image_path text,                       -- Supabase Storage path
  unit public.sell_unit not null default 'kg',
  low_stock_level numeric(12, 3) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- A product is sold in a currency only if it has a price row for it.
-- Tax lives here because AUD sales follow Australian rules and VND sales follow Vietnamese rules.
-- Customers see one price per unit: unit_price + logistics_fee (used for VND to cover shipping to Vietnam).
create table public.product_prices (
  product_id uuid not null references public.products (id) on delete cascade,
  currency public.currency_code not null,
  unit_price bigint not null check (unit_price >= 0),
  logistics_fee bigint not null default 0 check (logistics_fee >= 0),
  tax_rate numeric(5, 4) not null default 0 check (tax_rate >= 0 and tax_rate < 1),
  primary key (product_id, currency)
);

-- ---------------------------------------------------------------------------
-- Stock
-- ---------------------------------------------------------------------------

create table public.stock_batches (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  location_id uuid not null references public.locations (id),
  received_at timestamptz not null default now(),
  best_before date,
  supplier text,
  notes text
);

-- Ledger: current stock is the sum of quantity per product and shop. Positive = in, negative = out.
create table public.stock_movements (
  id bigint generated always as identity primary key,
  product_id uuid not null references public.products (id) on delete cascade,
  location_id uuid not null references public.locations (id),
  batch_id uuid references public.stock_batches (id) on delete set null,
  order_id uuid,                         -- FK added after orders exists
  reason public.stock_reason not null,
  quantity numeric(12, 3) not null check (quantity <> 0),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  note text
);

create index on public.stock_movements (product_id, location_id);

-- ---------------------------------------------------------------------------
-- Orders
-- ---------------------------------------------------------------------------

create sequence public.order_number_seq start 1001;

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number bigint not null unique default nextval('public.order_number_seq'),
  location_id uuid not null references public.locations (id),
  customer_id uuid references public.customers (id) on delete set null,  -- null = walk-in
  currency public.currency_code not null,  -- from the language in use: see currency_for_lang
  status public.order_status not null default 'draft',
  fulfilment public.fulfilment_type not null default 'pickup',
  payment_terms public.payment_terms not null default 'pay_now',
  delivery_address_id uuid references public.customer_addresses (id) on delete set null,
  subtotal bigint not null default 0,
  tax_total bigint not null default 0,
  delivery_fee bigint not null default 0 check (delivery_fee >= 0),
  total bigint not null default 0,
  notes text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  check (payment_terms <> 'on_account' or customer_id is not null)
);

create index on public.orders (customer_id);
create index on public.orders (location_id, created_at);

alter table public.stock_movements
  add constraint stock_movements_order_fk
  foreign key (order_id) references public.orders (id) on delete set null;

-- Name and price are copied onto the line so old orders don't change when the catalog does.
create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  product_id uuid not null references public.products (id),
  product_name_en text not null,
  product_name_vi text not null,
  unit public.sell_unit not null,
  quantity numeric(12, 3) not null check (quantity > 0),
  unit_price bigint not null check (unit_price >= 0),
  logistics_fee bigint not null default 0 check (logistics_fee >= 0),
  tax_rate numeric(5, 4) not null default 0,
  line_total bigint generated always as (round(quantity * (unit_price + logistics_fee))::bigint) stored
);

create index on public.order_items (order_id);

-- ---------------------------------------------------------------------------
-- Invoices and payments
-- ---------------------------------------------------------------------------

create sequence public.invoice_number_seq start 1;

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_number bigint not null unique default nextval('public.invoice_number_seq'),
  order_id uuid not null unique references public.orders (id),
  currency public.currency_code not null,
  total bigint not null,
  status public.invoice_status not null default 'unpaid',
  issued_at timestamptz not null default now(),
  due_at date
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices (id),
  method public.payment_method not null,
  currency public.currency_code not null,
  amount bigint not null check (amount <> 0),   -- negative = refund
  refund_of uuid references public.payments (id),
  stripe_payment_intent_id text unique,
  received_by uuid references public.profiles (id),
  received_at timestamptz not null default now(),
  note text
);

create index on public.payments (invoice_id);

-- ---------------------------------------------------------------------------
-- Deliveries
-- ---------------------------------------------------------------------------

create table public.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders (id) on delete cascade,
  address_id uuid references public.customer_addresses (id) on delete set null,
  driver_id uuid references public.profiles (id) on delete set null,
  status public.delivery_status not null default 'pending',
  window_start timestamptz,
  window_end timestamptz,
  proof_image_path text,
  delivered_at timestamptz
);

create index on public.deliveries (driver_id);

create table public.delivery_events (
  id bigint generated always as identity primary key,
  delivery_id uuid not null references public.deliveries (id) on delete cascade,
  status public.delivery_status not null,
  note text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Business rules
-- ---------------------------------------------------------------------------

-- Recalculate order totals whenever its lines change.
create function public.recalc_order_totals(p_order_id uuid) returns void
language sql as $$
  update public.orders o
  set subtotal  = coalesce(t.subtotal, 0),
      tax_total = coalesce(t.tax_total, 0),
      total     = coalesce(t.subtotal, 0) + coalesce(t.tax_total, 0) + o.delivery_fee
  from (
    select sum(line_total) as subtotal,
           sum(round(line_total * tax_rate))::bigint as tax_total
    from public.order_items
    where order_id = p_order_id
  ) t
  where o.id = p_order_id;
$$;

create function public.order_items_changed() returns trigger
language plpgsql as $$
begin
  perform public.recalc_order_totals(coalesce(new.order_id, old.order_id));
  return null;
end;
$$;

create trigger order_items_recalc
after insert or update or delete on public.order_items
for each row execute function public.order_items_changed();

create function public.orders_fee_changed() returns trigger
language plpgsql as $$
begin
  perform public.recalc_order_totals(new.id);
  return null;
end;
$$;

create trigger orders_fee_recalc
after update of delivery_fee on public.orders
for each row execute function public.orders_fee_changed();

-- Delivery orders pick up the shop's flat fee unless staff set one.
create function public.orders_default_fee() returns trigger
language plpgsql as $$
begin
  if new.fulfilment = 'delivery' and new.delivery_fee = 0 then
    select flat_fee into new.delivery_fee
    from public.delivery_fees
    where location_id = new.location_id and currency = new.currency;
    new.delivery_fee := coalesce(new.delivery_fee, 0);
  end if;
  return new;
end;
$$;

create trigger orders_fee_default
before insert on public.orders
for each row execute function public.orders_default_fee();

-- Deduct stock when an order is confirmed; put it back if a confirmed order is cancelled.
-- On-account orders are only allowed for customers with account terms.
create function public.orders_status_changed() returns trigger
language plpgsql as $$
begin
  if new.status = 'confirmed' and old.status = 'draft' then
    if new.payment_terms = 'on_account' and not exists (
      select 1 from public.customers where id = new.customer_id and account_terms_days is not null
    ) then
      raise exception 'Customer is not set up for invoice on account';
    end if;
    new.confirmed_at := now();
    insert into public.stock_movements (product_id, location_id, order_id, reason, quantity, created_by)
    select product_id, new.location_id, new.id, 'sold', -quantity, auth.uid()
    from public.order_items where order_id = new.id;
  elsif new.status = 'cancelled' and old.status not in ('draft', 'cancelled') then
    insert into public.stock_movements (product_id, location_id, order_id, reason, quantity, created_by)
    select product_id, new.location_id, new.id, 'returned', quantity, auth.uid()
    from public.order_items where order_id = new.id;
  end if;
  return new;
end;
$$;

create trigger orders_stock
before update of status on public.orders
for each row execute function public.orders_status_changed();

-- Invoice due date: on-account orders get the customer's terms, everything else is due on issue.
create function public.invoices_set_due() returns trigger
language plpgsql as $$
begin
  if new.due_at is null then
    select new.issued_at::date + case when o.payment_terms = 'on_account'
                                      then coalesce(c.account_terms_days, 0) else 0 end
    into new.due_at
    from public.orders o
    left join public.customers c on c.id = o.customer_id
    where o.id = new.order_id;
  end if;
  return new;
end;
$$;

create trigger invoices_due
before insert on public.invoices
for each row execute function public.invoices_set_due();

-- Keep invoice status in step with payments.
create function public.payments_changed() returns trigger
language plpgsql as $$
declare
  v_invoice_id uuid := coalesce(new.invoice_id, old.invoice_id);
  v_paid bigint;
  v_total bigint;
begin
  select coalesce(sum(amount), 0) into v_paid from public.payments where invoice_id = v_invoice_id;
  select total into v_total from public.invoices where id = v_invoice_id;
  update public.invoices
  set status = case
      when v_paid <= 0 then 'unpaid'::public.invoice_status
      when v_paid < v_total then 'part_paid'
      else 'paid'
    end
  where id = v_invoice_id and status <> 'void';
  return null;
end;
$$;

create trigger payments_invoice_status
after insert or update or delete on public.payments
for each row execute function public.payments_changed();

-- ---------------------------------------------------------------------------
-- Reporting views
-- ---------------------------------------------------------------------------

create view public.stock_levels with (security_invoker = true) as
select p.id as product_id, l.id as location_id, l.name as location_name,
       p.name_en, p.name_vi, p.unit,
       coalesce(sum(m.quantity), 0) as on_hand,
       coalesce(sum(m.quantity), 0) <= p.low_stock_level as is_low
from public.products p
cross join public.locations l
left join public.stock_movements m on m.product_id = p.id and m.location_id = l.id
group by p.id, l.id;

-- Prices as customers see them.
create view public.catalog_prices with (security_invoker = true) as
select pp.product_id, pp.currency, pp.unit_price + pp.logistics_fee as display_price, pp.tax_rate
from public.product_prices pp
join public.products p on p.id = pp.product_id
where p.is_active;

-- AUD and VND are always reported separately.
create view public.daily_sales with (security_invoker = true) as
select date_trunc('day', o.confirmed_at)::date as day, o.location_id, o.currency,
       count(*) as orders, sum(o.total) as revenue,
       sum((select coalesce(sum(round(i.quantity * i.logistics_fee)), 0)::bigint
            from public.order_items i where i.order_id = o.id)) as logistics_revenue
from public.orders o
where o.status not in ('draft', 'cancelled')
group by 1, 2, 3;

-- Unpaid and overdue invoices, for chasing account customers.
create view public.receivables with (security_invoker = true) as
select i.id as invoice_id, i.invoice_number, o.location_id, o.customer_id, i.currency, i.total,
       i.total - coalesce((select sum(amount) from public.payments p where p.invoice_id = i.id), 0) as balance,
       i.due_at, i.due_at < current_date as is_overdue
from public.invoices i
join public.orders o on o.id = i.order_id
where i.status in ('unpaid', 'part_paid');

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

create function public.my_role() returns public.app_role
language sql stable security definer set search_path = '' as $$
  select role from public.profiles where id = auth.uid();
$$;

create function public.is_staff() returns boolean
language sql stable as $$
  select coalesce(public.my_role() in ('owner', 'staff'), false);
$$;

create function public.my_customer_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select id from public.customers where profile_id = auth.uid();
$$;

alter table public.locations enable row level security;
alter table public.delivery_fees enable row level security;
alter table public.profiles enable row level security;
alter table public.customers enable row level security;
alter table public.customer_addresses enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_prices enable row level security;
alter table public.stock_batches enable row level security;
alter table public.stock_movements enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.invoices enable row level security;
alter table public.payments enable row level security;
alter table public.deliveries enable row level security;
alter table public.delivery_events enable row level security;

-- Staff and owner: full access to business data.
create policy staff_all on public.locations for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.delivery_fees for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.customers for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.customer_addresses for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.categories for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.products for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.product_prices for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.stock_batches for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.stock_movements for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.orders for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.order_items for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.invoices for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.payments for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.deliveries for all using (public.is_staff()) with check (public.is_staff());
create policy staff_all on public.delivery_events for all using (public.is_staff()) with check (public.is_staff());

-- Profiles: everyone sees their own; only the owner changes roles.
create policy own_profile on public.profiles for select using (id = auth.uid() or public.is_staff());
create policy owner_manage on public.profiles for all using (public.my_role() = 'owner') with check (public.my_role() = 'owner');

-- Public catalog: anyone (including logged-out visitors) can read active products.
create policy read_catalog on public.locations for select using (is_active);
create policy read_catalog on public.delivery_fees for select using (true);
create policy read_catalog on public.categories for select using (true);
create policy read_catalog on public.products for select using (is_active);
create policy read_catalog on public.product_prices for select using (true);

-- Customers: their own record, addresses, orders, invoices and deliveries.
create policy own_customer on public.customers for select using (profile_id = auth.uid());
create policy own_addresses on public.customer_addresses for all
  using (customer_id = public.my_customer_id()) with check (customer_id = public.my_customer_id());
create policy own_orders on public.orders for select using (customer_id = public.my_customer_id());
create policy own_order_items on public.order_items for select
  using (exists (select 1 from public.orders o where o.id = order_id and o.customer_id = public.my_customer_id()));
create policy own_invoices on public.invoices for select
  using (exists (select 1 from public.orders o where o.id = order_id and o.customer_id = public.my_customer_id()));
create policy own_deliveries on public.deliveries for select
  using (exists (select 1 from public.orders o where o.id = order_id and o.customer_id = public.my_customer_id()));
-- Customers place orders through place_customer_order (0002) so prices and stock are checked server-side.

-- Drivers: their assigned deliveries only.
create policy driver_deliveries on public.deliveries for select using (driver_id = auth.uid());
create policy driver_update on public.deliveries for update
  using (driver_id = auth.uid()) with check (driver_id = auth.uid());
create policy driver_events on public.delivery_events for insert
  with check (exists (select 1 from public.deliveries d where d.id = delivery_id and d.driver_id = auth.uid()));
