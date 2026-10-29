-- End-to-end check of the order flow, run against a database with migrations and seed.sql applied.
-- Everything runs in one transaction and is rolled back, so it leaves no data behind.
-- Run: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/smoke_test.sql

begin;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAILED: %', what; end if;
  raise notice 'ok: %', what;
end $$;

-- Runs p_sql and passes only if it raises an error.
create function pg_temp.check_fails(p_sql text, what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAILED (no error): %', what;
exception when others then
  if sqlerrm like 'FAILED (no error)%' then raise; end if;
  raise notice 'ok: % (%)', what, sqlerrm;
end $$;

-- Users: a Vietnamese-speaking customer, a staff member and a driver.
insert into auth.users (id, email, raw_user_meta_data) values
  ('d0000000-0000-0000-0000-00000000000c', 'customer@test.local', '{"full_name": "Lan", "lang": "vi"}'),
  ('d0000000-0000-0000-0000-000000000005', 'staff@test.local', '{"full_name": "Sam"}'),
  ('d0000000-0000-0000-0000-00000000000d', 'driver@test.local', '{"full_name": "Duc"}');

select pg_temp.check((select count(*) = 3 from public.customers where email like '%@test.local'),
                     'sign-up creates customer records');
select pg_temp.check((select preferred_lang = 'vi' from public.profiles where id = 'd0000000-0000-0000-0000-00000000000c'),
                     'sign-up keeps chosen language');

update public.profiles set role = 'staff', location_id = 'a0000000-0000-0000-0000-000000000002'
where id = 'd0000000-0000-0000-0000-000000000005';
update public.profiles set role = 'driver' where id = 'd0000000-0000-0000-0000-00000000000d';

insert into public.stock_movements (product_id, location_id, reason, quantity) values
  ('c0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'received', 10);
insert into public.customer_addresses (id, customer_id, line1, city, country)
select 'e0000000-0000-0000-0000-000000000001', id, '1 Le Loi', 'Ho Chi Minh City', 'VN'
from public.customers where profile_id = 'd0000000-0000-0000-0000-00000000000c';

-- Customer --------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub": "d0000000-0000-0000-0000-00000000000c", "role": "authenticated"}';

select pg_temp.check((select count(*) = 1 from public.customers), 'customer sees only their own record');
select pg_temp.check((select display_price = 400000 from public.catalog_prices
                      where product_id = 'c0000000-0000-0000-0000-000000000001' and currency = 'VND'),
                     'VND price includes logistics fee');

select pg_temp.check_fails($$ update public.profiles set role = 'owner' $$, 'customer cannot change own role');
select pg_temp.check_fails($$
  select public.place_customer_order('a0000000-0000-0000-0000-000000000002', 'vi', 'pickup',
    '[{"product_id": "c0000000-0000-0000-0000-000000000001", "quantity": 99}]')
$$, 'cannot order more than stock');
select pg_temp.check_fails($$
  select public.place_customer_order('a0000000-0000-0000-0000-000000000002', 'vi', 'pickup',
    '[{"product_id": "c0000000-0000-0000-0000-000000000001", "quantity": 1}]', null, 'on_account')
$$, 'non-account customer cannot buy on account');

select public.place_customer_order('a0000000-0000-0000-0000-000000000002', 'vi', 'delivery',
  '[{"product_id": "c0000000-0000-0000-0000-000000000001", "quantity": 2}]',
  'e0000000-0000-0000-0000-000000000001');

select pg_temp.check((select currency = 'VND' and total = 800000 and status = 'confirmed'
                        and payment_terms = 'pay_on_delivery' from public.orders),
                     'Vietnamese order is in VND, confirmed, pay on delivery');
select pg_temp.check((select status = 'unpaid' and total = 800000 from public.invoices), 'invoice issued on confirm');
select pg_temp.check((select status = 'pending' from public.deliveries), 'delivery opened on confirm');

-- Staff: assign the driver -----------------------------------------------------
set local request.jwt.claims = '{"sub": "d0000000-0000-0000-0000-000000000005", "role": "authenticated"}';

select pg_temp.check((select on_hand = 8 from public.stock_levels
                      where product_id = 'c0000000-0000-0000-0000-000000000001'
                        and location_id = 'a0000000-0000-0000-0000-000000000002'),
                     'stock deducted at the Vietnam shop');
update public.deliveries set driver_id = 'd0000000-0000-0000-0000-00000000000d', status = 'assigned';
select pg_temp.check_fails($$
  insert into public.order_items (order_id, product_id, product_name_en, product_name_vi, unit, quantity, unit_price)
  select id, 'c0000000-0000-0000-0000-000000000002', 'Apples', 'Táo', 'kg', 1, 1 from public.orders
$$, 'confirmed order lines are locked');

-- Driver ----------------------------------------------------------------------
set local request.jwt.claims = '{"sub": "d0000000-0000-0000-0000-00000000000d", "role": "authenticated"}';

select pg_temp.check((select count(*) = 1 from public.deliveries), 'driver sees their delivery');
select pg_temp.check((select count(*) = 0 from public.customers where profile_id is distinct from auth.uid()),
                     'driver cannot browse customers');
-- Direct updates are filtered out by row level security, so they change nothing.
update public.deliveries set status = 'delivered';
select pg_temp.check((select status = 'assigned' from public.deliveries), 'direct driver update has no effect');

select public.update_delivery_status(id, 'out_for_delivery') from public.deliveries;
select public.update_delivery_status(id, 'delivered', 'Left with reception', 800000) from public.deliveries;

reset role;
select pg_temp.check((select status = 'completed' from public.orders), 'order completed on delivery');
select pg_temp.check((select status = 'paid' from public.invoices), 'cash on delivery pays the invoice');
select pg_temp.check((select count(*) = 2 from public.delivery_events), 'delivery history recorded');

select 'ALL CHECKS PASSED' as result;
rollback;
