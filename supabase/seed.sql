-- Sample data for local development and first look. Replace prices and stock with the owner's spreadsheet.
-- Amounts are in the smallest unit: AUD cents, VND dong.

insert into public.locations (id, name, country) values
  ('a0000000-0000-0000-0000-000000000001', 'Australia shop', 'AU'),
  ('a0000000-0000-0000-0000-000000000002', 'Vietnam shop', 'VN');

-- Placeholder flat delivery fees until the owner confirms them.
insert into public.delivery_fees (location_id, currency, flat_fee) values
  ('a0000000-0000-0000-0000-000000000001', 'AUD', 0),
  ('a0000000-0000-0000-0000-000000000001', 'VND', 0),
  ('a0000000-0000-0000-0000-000000000002', 'AUD', 0),
  ('a0000000-0000-0000-0000-000000000002', 'VND', 0);

insert into public.categories (id, name_en, name_vi, sort_order) values
  ('b0000000-0000-0000-0000-000000000001', 'Fresh fruit', 'Trái cây tươi', 1);

insert into public.products (id, sku, category_id, name_en, name_vi, unit, low_stock_level) values
  ('c0000000-0000-0000-0000-000000000001', 'CHERRY', 'b0000000-0000-0000-0000-000000000001', 'Cherries', 'Anh đào', 'kg', 5),
  ('c0000000-0000-0000-0000-000000000002', 'APPLE',  'b0000000-0000-0000-0000-000000000001', 'Apples',   'Táo',     'kg', 10),
  ('c0000000-0000-0000-0000-000000000003', 'ORANGE', 'b0000000-0000-0000-0000-000000000001', 'Oranges',  'Cam',     'kg', 10);

-- Placeholder prices. VND prices include a placeholder logistics fee.
insert into public.product_prices (product_id, currency, unit_price, logistics_fee, tax_rate) values
  ('c0000000-0000-0000-0000-000000000001', 'AUD', 2000, 0, 0),
  ('c0000000-0000-0000-0000-000000000001', 'VND', 350000, 50000, 0),
  ('c0000000-0000-0000-0000-000000000002', 'AUD', 600, 0, 0),
  ('c0000000-0000-0000-0000-000000000002', 'VND', 100000, 20000, 0),
  ('c0000000-0000-0000-0000-000000000003', 'AUD', 500, 0, 0),
  ('c0000000-0000-0000-0000-000000000003', 'VND', 80000, 20000, 0);
