# Fruit Shop: product spec (v0.2, draft)

## 1. Goal

One system for a fruit business with shops in Australia and Vietnam. It lets the business take orders in the shop, on the phone and from customers' own phones, then invoice, collect payment, manage stock, deliver and see sales, in English or Vietnamese, priced in AUD or VND.

## 2. Platforms and stack

| Part | Runs on | Built with |
| --- | --- | --- |
| Staff and owner POS app | Windows, macOS, iPad, Android tablet | Flutter |
| Customer app | iOS, Android | Flutter (same codebase, separate app entry point) |
| Driver screens | Phone | Inside the staff app, limited to the driver role |
| Backend | Cloud | Supabase (Postgres, Auth, Storage, Edge Functions) |
| Payments | Cloud and card reader | Stripe (online card payments; Stripe Terminal for in-shop card readers) |

One Flutter codebase keeps features, translations and business rules identical across all four platforms.

## 3. Shops

- The business has shops in **Australia** and **Vietnam**. Each shop has its own stock, staff, flat delivery fee and sales figures.
- Every order, stock movement and report belongs to one shop. The owner can see all shops together or one at a time.
- Staff are assigned a home shop, which the POS app opens by default.

## 4. Roles

| Role | Who | Can do |
| --- | --- | --- |
| Owner | Business owner | Everything, including prices, staff accounts and reports |
| Staff | Shop and office staff | Create orders and invoices, take payments, manage customers and stock, assign deliveries |
| Driver | Delivery staff | See their assigned deliveries, update status, capture proof of delivery, collect cash on delivery |
| Customer | Public | Browse the catalog, place and pay for orders, track their deliveries, see their order history |

A customer record can exist without a login (walk-in or phone customers that staff enter).

Drivers do not get a separate app. They sign in to the staff app on their phone and see only the driver view.

## 5. Features (version 1)

### 5.1 Product catalog
- Products have an English and a Vietnamese name and description, a photo, a category and a selling unit: per kg, per box, or each.
- Each product has a price in AUD and/or VND, each with its own tax rate. A product without a price in a currency is not sold in that currency.
- VND prices include a **logistics fee** per unit to cover getting the fruit to Vietnam, so they cost more than the AUD price. Customers see one combined price; the fee is stored separately so reports can show product sales and logistics income apart.
- Products can be marked inactive (hidden from sale) without deleting history.
- Starting products: cherries, apples, oranges. The full list is imported from the owner's spreadsheet.

### 5.2 Customers
- Name, phone, email, preferred language (which also sets their currency), notes.
- Regular business customers also have a business name, tax ID (ABN or MST), account terms (for example 30 days) and an optional credit limit. Only these customers can buy on account.
- One or more delivery addresses.
- Order and payment history per customer.

### 5.3 Orders (POS)
- Staff pick a customer (or "walk-in"), add products and quantities (weights allowed, e.g. 2.5 kg), and choose pickup or delivery.
- Each order belongs to one shop and is in one currency, set by the language in use (section 6).
- Each order has payment terms: **pay now** (in the shop), **pay on delivery**, or **on account** (business customers with account terms only; invoice due after their terms). Totals are calculated by the database, not the app, so every device agrees.
- Order statuses: draft, confirmed, packed, out for delivery, completed, cancelled.
- Customers place the same kind of order from the customer app and choose a shop. In version 1 they pay on delivery or on pickup, since payments are cash only to start.

### 5.4 Invoices
- An invoice is created from an order with its own sequential number. Its due date is the issue date, or issue date plus the customer's account terms for on-account orders.
- Printable and shareable as PDF, in the customer's language.
- Statuses: unpaid, part-paid, paid, void.
- An "unpaid and overdue" list shows what each account customer owes.

### 5.5 Payments
- **Version 1: cash only.** Cash is taken in the shop, by the driver on delivery, or against an on-account invoice.
- Later: card in shop (Stripe Terminal), card online (Stripe), bank transfer. The database already has room for these.
- Partial payments are allowed; an invoice is paid when payments cover its total.
- Refunds are recorded as negative payments linked to the original.

### 5.6 Stock control
- Stock is tracked per product and per shop as a ledger of movements: received, sold, wasted/spoiled, adjusted, returned.
- Current stock = sum of movements. Confirming an order deducts stock automatically; cancelling puts it back.
- Received stock can carry a batch with a best-before date, so staff can sell oldest first and see what is about to spoil.
- Low-stock alert level per product.

### 5.7 Deliveries
- A delivery order gets a delivery record: address, time window, assigned driver.
- Each shop has a flat delivery fee per currency, added to delivery orders automatically. Staff can override it on an order. The amounts are still to be agreed.
- Statuses: pending, assigned, out for delivery, delivered, failed.
- Drivers update status from their phone and can attach a photo or signature as proof.
- Customers see the current status in their app.

### 5.8 Sales reports (owner)
- Sales by day, week and month, per shop and per currency (AUD and VND are never added together).
- Top products, sales by customer, sales by staff member.
- Stock value, waste/spoilage, unpaid invoices.
- Export to CSV.

## 6. Languages and currency

- All app text is translated into English and Vietnamese (Flutter ARB files). The user can switch at any time.
- **Currency follows language:** English shows prices in AUD, Vietnamese shows prices in VND. Switching language switches the currency. The database has a `currency_for_lang` function so every app applies the same rule.
- Product names and descriptions are stored in both languages in the database.
- Invoices and customer messages use the customer's preferred language.

## 7. Money rules

- Amounts are stored as whole numbers in the currency's smallest unit: cents for AUD, dong for VND (VND has no decimal places). This avoids rounding errors and matches how Stripe charges both currencies.
- Each price, order, invoice and payment carries its currency. There is no automatic conversion between AUD and VND in version 1.
- Tax: each product price has a tax rate (default 0%), so AUD and VND prices can follow different tax rules. Fresh fruit is generally GST-free in Australia; the Vietnamese VAT treatment needs confirming with the owner's accountant.

## 8. Data model (summary)

Full draft schema: [`supabase/migrations/0001_init.sql`](../supabase/migrations/0001_init.sql).

```
locations (shops) ── delivery_fees
profiles (login accounts + role + home shop)
customers ── customer_addresses
categories ── products ── product_prices (per currency)
products ── stock_batches ── stock_movements
orders ── order_items
orders ── invoices ── payments
orders ── deliveries ── delivery_events
```

## 9. Not in version 1

- Card and online payments (cash only to start)
- Delivery fees other than a flat fee per shop
- Automatic AUD/VND exchange rates
- Loyalty points and discount codes
- Supplier purchase orders
- Offline mode for the POS app (worth revisiting if the shop's internet is unreliable)

## 10. Decisions and open questions

Decided by the owner on 2026-10-29:

1. Shops in both Australia and Vietnam.
2. Currency follows language: English = AUD, Vietnamese = VND.
3. Payment terms needed: pay in shop, pay on delivery, and invoice on account for regular business customers.
4. Cash payments first; card payments later.
5. No separate driver app; drivers use a driver view in the staff app.
6. Delivery fee: most likely a flat fee, amounts to be discussed.
7. Choosing Vietnamese shows VND prices at any shop. VND prices include a logistics fee, so they are higher.

Still open:

1. The flat delivery fee for each shop.
2. Vietnamese VAT on fresh fruit (check with the accountant).
3. The product spreadsheet (coming from the owner).
4. The logistics fee per product (or per kg) for VND prices.
