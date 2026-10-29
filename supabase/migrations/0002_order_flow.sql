-- Fruit Shop: order flow, sign-up, drivers and hardening.

-- ---------------------------------------------------------------------------
-- Hardening: fixed search_path on functions from 0001
-- ---------------------------------------------------------------------------

alter function public.currency_for_lang(public.lang_code) set search_path = '';
alter function public.recalc_order_totals(uuid) set search_path = '';
alter function public.order_items_changed() set search_path = '';
alter function public.orders_fee_changed() set search_path = '';
alter function public.orders_default_fee() set search_path = '';
alter function public.orders_status_changed() set search_path = '';
alter function public.invoices_set_due() set search_path = '';
alter function public.payments_changed() set search_path = '';
alter function public.is_staff() set search_path = '';

revoke execute on function public.recalc_order_totals(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Sign-up: every new login gets a profile and a customer record
-- ---------------------------------------------------------------------------

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := coalesce(new.raw_user_meta_data ->> 'full_name', '');
  v_lang public.lang_code := case when new.raw_user_meta_data ->> 'lang' = 'vi' then 'vi' else 'en' end;
begin
  insert into public.profiles (id, role, full_name, preferred_lang)
  values (new.id, 'customer', v_name, v_lang);
  insert into public.customers (profile_id, full_name, email, preferred_lang)
  values (new.id, v_name, new.email, v_lang);
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- Users may edit their own name, phone and language, never their role or shop.
revoke update on public.profiles from anon, authenticated;
grant update (full_name, phone, preferred_lang) on public.profiles to authenticated;
create policy own_profile_update on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- The owner sets staff roles and home shops.
create function public.set_user_role(p_user_id uuid, p_role public.app_role, p_location_id uuid default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.my_role() is distinct from 'owner' then
    raise exception 'Only the owner can change roles';
  end if;
  update public.profiles set role = p_role, location_id = p_location_id where id = p_user_id;
end;
$$;

revoke execute on function public.set_user_role(uuid, public.app_role, uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- Orders
-- ---------------------------------------------------------------------------

-- Lines are frozen once an order leaves draft, so stock and invoices stay correct.
create function public.order_items_lock() returns trigger
language plpgsql set search_path = '' as $$
begin
  if exists (
    select 1 from public.orders
    where id = coalesce(new.order_id, old.order_id) and status <> 'draft'
  ) then
    raise exception 'Order lines can only change while the order is a draft';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger order_items_lock
before insert or update or delete on public.order_items
for each row execute function public.order_items_lock();

-- On confirm: issue the invoice, and open a delivery for delivery orders.
create function public.orders_after_confirm() returns trigger
language plpgsql set search_path = '' as $$
begin
  insert into public.invoices (order_id, currency, total)
  values (new.id, new.currency, new.total)
  on conflict (order_id) do nothing;

  if new.fulfilment = 'delivery' then
    insert into public.deliveries (order_id, address_id)
    values (new.id, new.delivery_address_id)
    on conflict (order_id) do nothing;
  end if;
  return null;
end;
$$;

create trigger orders_confirmed
after update of status on public.orders
for each row
when (new.status = 'confirmed' and old.status = 'draft')
execute function public.orders_after_confirm();

-- Cancelling an order voids its invoice and stops its delivery.
create function public.orders_after_cancel() returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.invoices set status = 'void' where order_id = new.id;
  update public.deliveries set status = 'failed'
  where order_id = new.id and status not in ('delivered', 'failed');
  return null;
end;
$$;

create trigger orders_cancelled
after update of status on public.orders
for each row
when (new.status = 'cancelled' and old.status <> 'cancelled')
execute function public.orders_after_cancel();

-- Customer app: place an order. Prices, currency and stock are checked here, not in the app.
-- p_items: [{"product_id": "...", "quantity": 2.5}, ...]
create function public.place_customer_order(
  p_location_id uuid,
  p_lang public.lang_code,
  p_fulfilment public.fulfilment_type,
  p_items jsonb,
  p_address_id uuid default null,
  p_payment_terms public.payment_terms default null,
  p_notes text default null
) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_customer public.customers;
  v_currency public.currency_code := public.currency_for_lang(p_lang);
  v_terms public.payment_terms;
  v_order_id uuid;
  v_order_number bigint;
  v_item record;
  v_on_hand numeric;
begin
  select * into v_customer from public.customers where profile_id = auth.uid();
  if v_customer.id is null then
    raise exception 'Sign in to place an order';
  end if;

  if not exists (select 1 from public.locations where id = p_location_id and is_active) then
    raise exception 'Unknown shop';
  end if;

  if p_fulfilment = 'delivery' and not exists (
    select 1 from public.customer_addresses where id = p_address_id and customer_id = v_customer.id
  ) then
    raise exception 'Choose a delivery address';
  end if;

  v_terms := coalesce(p_payment_terms,
                      case p_fulfilment when 'delivery' then 'pay_on_delivery'::public.payment_terms
                                        else 'pay_now'::public.payment_terms end);
  if v_terms = 'on_account' and v_customer.account_terms_days is null then
    raise exception 'Your account is not set up for invoice on account';
  end if;

  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The order has no items';
  end if;

  -- One order at a time per shop, so two customers can't both take the last box.
  perform pg_advisory_xact_lock(hashtext(p_location_id::text));

  insert into public.orders (location_id, customer_id, currency, fulfilment, payment_terms,
                             delivery_address_id, notes, created_by)
  values (p_location_id, v_customer.id, v_currency, p_fulfilment, v_terms,
          case when p_fulfilment = 'delivery' then p_address_id end, p_notes, auth.uid())
  returning id, order_number into v_order_id, v_order_number;

  for v_item in
    select (e ->> 'product_id')::uuid as product_id, sum((e ->> 'quantity')::numeric) as quantity
    from jsonb_array_elements(p_items) e
    group by 1
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'Quantities must be more than zero';
    end if;

    select coalesce(sum(quantity), 0) into v_on_hand
    from public.stock_movements
    where product_id = v_item.product_id and location_id = p_location_id;

    insert into public.order_items (order_id, product_id, product_name_en, product_name_vi, unit,
                                    quantity, unit_price, logistics_fee, tax_rate)
    select v_order_id, p.id, p.name_en, p.name_vi, p.unit,
           v_item.quantity, pp.unit_price, pp.logistics_fee, pp.tax_rate
    from public.products p
    join public.product_prices pp on pp.product_id = p.id and pp.currency = v_currency
    where p.id = v_item.product_id and p.is_active;

    if not found then
      raise exception 'Product % is not for sale in %', v_item.product_id, v_currency;
    end if;
    if v_on_hand < v_item.quantity then
      raise exception 'Not enough stock for product %', v_item.product_id;
    end if;
  end loop;

  update public.orders set status = 'confirmed' where id = v_order_id;
  return v_order_number;
end;
$$;

revoke execute on function public.place_customer_order(uuid, public.lang_code, public.fulfilment_type, jsonb, uuid, public.payment_terms, text) from public, anon;

-- ---------------------------------------------------------------------------
-- Deliveries: drivers update status and record cash through this function only
-- ---------------------------------------------------------------------------

drop policy driver_update on public.deliveries;
drop policy driver_events on public.delivery_events;

create function public.update_delivery_status(
  p_delivery_id uuid,
  p_status public.delivery_status,
  p_note text default null,
  p_cash_collected bigint default null,
  p_proof_image_path text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_delivery public.deliveries;
  v_order public.orders;
begin
  select * into v_delivery from public.deliveries where id = p_delivery_id for update;
  if v_delivery.id is null
     or not (v_delivery.driver_id = auth.uid() or public.is_staff()) then
    raise exception 'Delivery not found';
  end if;
  if p_status not in ('out_for_delivery', 'delivered', 'failed') then
    raise exception 'Drivers can only set out for delivery, delivered or failed';
  end if;

  select * into v_order from public.orders where id = v_delivery.order_id;
  if v_order.status = 'cancelled' then
    raise exception 'This order was cancelled';
  end if;

  update public.deliveries
  set status = p_status,
      proof_image_path = coalesce(p_proof_image_path, proof_image_path),
      delivered_at = case when p_status = 'delivered' then now() else delivered_at end
  where id = p_delivery_id;

  insert into public.delivery_events (delivery_id, status, note, created_by)
  values (p_delivery_id, p_status, p_note, auth.uid());

  update public.orders
  set status = case p_status when 'out_for_delivery' then 'out_for_delivery'::public.order_status
                             when 'delivered' then 'completed'::public.order_status
                             else status end
  where id = v_order.id;

  if coalesce(p_cash_collected, 0) > 0 then
    insert into public.payments (invoice_id, method, currency, amount, received_by, note)
    select i.id, 'cash', i.currency, p_cash_collected, auth.uid(), 'Collected on delivery'
    from public.invoices i where i.order_id = v_order.id;
  end if;
end;
$$;

revoke execute on function public.update_delivery_status(uuid, public.delivery_status, text, bigint, text) from public, anon;

-- Ownership checks used by policies. Security definer so policies on orders and deliveries
-- don't call each other in a loop.
create function public.is_my_order(p_order_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.orders where id = p_order_id and customer_id = public.my_customer_id());
$$;

create function public.is_my_delivery_order(p_order_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.deliveries where order_id = p_order_id and driver_id = auth.uid());
$$;

drop policy own_order_items on public.order_items;
drop policy own_invoices on public.invoices;
drop policy own_deliveries on public.deliveries;
create policy own_order_items on public.order_items for select using (public.is_my_order(order_id));
create policy own_invoices on public.invoices for select using (public.is_my_order(order_id));
create policy own_deliveries on public.deliveries for select using (public.is_my_order(order_id));

-- Drivers can see the order, lines and address for their deliveries.
create policy driver_orders on public.orders for select using (public.is_my_delivery_order(id));
create policy driver_order_items on public.order_items for select using (public.is_my_delivery_order(order_id));
create policy driver_addresses on public.customer_addresses for select
  using (exists (select 1 from public.deliveries d where d.address_id = customer_addresses.id and d.driver_id = auth.uid()));
create policy driver_events_read on public.delivery_events for select
  using (exists (select 1 from public.deliveries d where d.id = delivery_id and d.driver_id = auth.uid()));
