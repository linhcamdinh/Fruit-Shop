# Fruit Shop

POS and ordering system for a fruit sale business.

- **Staff and owner app:** Windows, macOS and tablets (order entry, invoices, stock, deliveries, sales reports)
- **Customer app:** iOS and Android (browse, order, pay, track delivery)
- **Languages:** English and Vietnamese
- **Currencies:** AUD and VND

## Docs

- [Spec](docs/SPEC.md): roles, screens, business rules and open questions
- [Database schema](supabase/migrations/): Supabase migrations (tables, business rules, security)

## Backend

The database runs on Supabase (project "Fruit Shop", Singapore region).

- `supabase/migrations/`: schema and business rules, applied in order
- `supabase/seed.sql`: sample shops and products with placeholder prices
- `supabase/tests/smoke_test.sql`: end-to-end check of ordering, stock, invoices and deliveries. It runs in a transaction and rolls back.

Run locally with the Supabase CLI: `npx supabase start`, then `npx supabase db reset` to apply migrations and seed. Run the smoke test with `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/smoke_test.sql`.

App entry points (functions called from the apps):

| Function | Who | What |
| --- | --- | --- |
| `place_customer_order` | Customer | Places an order; checks prices, currency (from language) and stock |
| `update_delivery_status` | Driver | Out for delivery, delivered (with cash collected), or failed |
| `set_user_role` | Owner | Makes a user staff, driver or owner and sets their shop |

## Plan

1. Spec and data design (done)
2. Backend: Supabase database, logins and roles (this step; card payments later)
3. Staff and owner POS app (Flutter, desktop and tablet)
4. Customer ordering app (Flutter, iOS and Android)
