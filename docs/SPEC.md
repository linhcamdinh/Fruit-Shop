# Fruit Shop: product spec (v0.1, draft)

## 1. Goal

One system that lets a fruit business take orders in the shop, on the phone and from customers' own phones, then invoice, collect payment, manage stock, deliver and see sales, in English or Vietnamese, priced in AUD or VND.

## 2. Platforms and stack

| Part | Runs on | Built with |
| --- | --- | --- |
| Staff and owner POS app | Windows, macOS, iPad, Android tablet | Flutter |
| Customer app | iOS, Android | Flutter (same codebase, separate app entry point) |
| Driver screens | Phone | Inside the staff app, limited to the driver role |
| Backend | Cloud | Supabase (Postgres, Auth, Storage, Edge Functions) |
| Payments | Cloud and card reader | Stripe (online card payments; Stripe Terminal for in-shop card readers) |

One Flutter codebase keeps features, translations and business rules identical across all four platforms.

## 3. Roles

| Role | Who | Can do |
| --- | --- | --- |
| Owner | Business owner | Everything, including prices, staff accounts and reports |
| Staff | Shop and office staff | Create orders and invoices, take payments, manage customers and stock, assign deliveries |
| Driver | Delivery staff | See their assigned deliveries, update status, capture proof of delivery |
| Customer | Public | Browse the catalog, place and pay for orders, track their deliveries, see their order history |

A customer record can exist without a login (walk-in or phone customers that staff enter).

## 4. Features (version 1)

### 4.1 Product catalog
- Products have an English and a Vietnamese name and description, a photo, a category and a selling unit: per kg, per box, or each.
- Each product has a price in AUD and/or VND. A product without a price in a currency is not sold in that currency.
- Products can be marked inactive (hidden from sale) without deleting history.
- Starting products: cherries, apples, oranges. The full list is imported from the owner's spreadsheet.

### 4.2 Customers
- Name, phone, email, preferred language, preferred currency, notes.
- One or more delivery addresses.
- Order and payment history per customer.

### 4.3 Orders (POS)
- Staff pick a customer (or "walk-in"), add products and quantities (weights allowed, e.g. 2.5 kg), and choose pickup or delivery.
- Each order is in one currency. Totals are calculated by the database, not the app, so every device agrees.
- Order statuses: draft, confirmed, packed, out for delivery, completed, cancelled.
- Customers place the same kind of order from the customer app; it arrives as "confirmed" once paid, or "confirmed, unpaid" if pay-on-delivery is allowed.

### 4.4 Invoices
- An invoice is created from an order with its own sequential number.
- Printable and shareable as PDF, in the customer's language.
- Statuses: unpaid, part-paid, paid, void.

### 4.5 Payments
- Methods: cash, card in shop (Stripe Terminal), card online (Stripe), bank transfer (recorded manually).
- Partial payments are allowed; an invoice is paid when payments cover its total.
- Refunds are recorded as negative payments linked to the original.

### 4.6 Stock control
- Stock is tracked per product as a ledger of movements: received, sold, wasted/spoiled, adjusted, returned.
- Current stock = sum of movements. Confirming an order deducts stock automatically; cancelling puts it back.
- Received stock can carry a batch with a best-before date, so staff can sell oldest first and see what is about to spoil.
- Low-stock alert level per product.

### 4.7 Deliveries
- A delivery order gets a delivery record: address, time window, assigned driver.
- Statuses: pending, assigned, out for delivery, delivered, failed.
- Drivers update status from their phone and can attach a photo or signature as proof.
- Customers see the current status in their app.

### 4.8 Sales reports (owner)
- Sales by day, week and month, per currency (AUD and VND are never added together).
- Top products, sales by customer, sales by staff member.
- Stock value, waste/spoilage, unpaid invoices.
- Export to CSV.

## 5. Languages

- All app text is translated into English and Vietnamese (Flutter ARB files). The user can switch at any time.
- Product names and descriptions are stored in both languages in the database.
- Invoices and customer messages use the customer's preferred language.

## 6. Money rules

- Amounts are stored as whole numbers in the currency's smallest unit: cents for AUD, dong for VND (VND has no decimal places). This avoids rounding errors and matches how Stripe charges both currencies.
- Each price, order, invoice and payment carries its currency. There is no automatic conversion between AUD and VND in version 1.
- Tax: each product has a tax rate (default 0%). Fresh fruit is generally GST-free in Australia; the Vietnamese VAT treatment needs confirming with the owner's accountant.

## 7. Data model (summary)

Full draft schema: [`supabase/migrations/0001_init.sql`](../supabase/migrations/0001_init.sql).

```
profiles (login accounts + role)
customers ── customer_addresses
categories ── products ── product_prices (per currency)
products ── stock_batches ── stock_movements
orders ── order_items
orders ── invoices ── payments
orders ── deliveries ── delivery_events
```

## 8. Not in version 1

- Multiple shops or warehouses (the schema can add a `location` later)
- Automatic AUD/VND exchange rates
- Loyalty points and discount codes
- Supplier purchase orders
- Offline mode for the POS app (worth revisiting if the shop's internet is unreliable)

## 9. Open questions for the owner

1. Where does the business operate: a shop in Australia, in Vietnam, or both? (This decides which currency each customer sees by default and which tax rules apply.)
2. Do you need pay-on-delivery or invoice-on-account for regular business customers?
3. Do you want in-shop card readers (Stripe Terminal), or cash and online payments only to start?
4. Do drivers need a separate simple app, or is a driver view in the staff app enough?
5. Any delivery fee rules (flat, by distance, free over a certain amount)?
