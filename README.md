# Fruit Shop

POS and ordering system for a fruit sale business.

- **Staff and owner app:** Windows, macOS and tablets (order entry, invoices, stock, deliveries, sales reports)
- **Customer app:** iOS and Android (browse, order, pay, track delivery)
- **Languages:** English and Vietnamese
- **Currencies:** AUD and VND

## Docs

- [Spec](docs/SPEC.md): roles, screens, business rules and open questions
- [Database schema](supabase/migrations/0001_init.sql): draft Postgres schema for Supabase

## Plan

1. Spec and data design (this step)
2. Backend: Supabase database, logins and roles, Stripe payments
3. Staff and owner POS app (Flutter, desktop and tablet)
4. Customer ordering app (Flutter, iOS and Android)
