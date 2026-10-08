# Payment options (schema file 1056, migration 1.37.0)

Design reference: Analysis and Design Study v3.3, section 6.9 (`docs/Masslak_Analysis_and_Design_EN_v3.3.docx`).

Owner decision, October 2026: Syria has few licensed e-wallet and card providers today, so the pilot and release 1 must
not depend on them. Travellers can pay in cash at the carrier, and platform administration decides which ways of paying
are open. Each electronic option opens once a provider is contracted and set up, with no code change.

## 1. The options

| Code | What the payer does | Channels | Opens when | New install |
|---|---|---|---|---|
| `WALLET` | Pays at once from the platform wallet (topped up by card, e-wallet, bank transfer or cash at an agency) | Website, app | always available | open |
| `AGENCY_BALANCE` | An agency sells from its prepaid balance and takes the traveller's cash itself | Agencies | always available | open |
| `CASH_COUNTER` | The carrier's counter or station staff sell a ticket for cash (study 6.5) | Carrier counters | always available | open |
| `PAY_LATER` | The passenger reserves online and pays cash at the carrier's counter before departure | Website, app | always available | open |
| `CARD` | Pays by card at checkout through a contracted gateway (for example HyperPay or Amazon Payment Services) | Website, app | a `HOSTED_CARD` provider is active for bookings | closed |
| `INSTALLMENT` | Pays in instalments through a contracted provider (Tabby, Tamara or a local equivalent, where licensed) | Website, app | an `INSTALLMENT` provider is active for bookings | closed |
| `FINANCING` | A financing company pays a high-value trip (Umrah, Hajj, tours) and recovers it from the traveller | Website, app | a `FINANCING` provider is active for bookings | closed |

Platform administration changes an option in **Payments > Booking payment options** (permission `payment.methods`,
held by the platform administrator and finance): open or close it, the channels it is offered on, the minimum and maximum
amount, and its settings. Every change needs a reason and is kept in the activity log.

The database enforces the rules whatever screen or script is used:

- an option that needs a provider does not open while no such provider is active for bookings (`NO_ACTIVE_PROVIDER`);
- a provider an open option relies on cannot be switched off (`PROVIDER_IN_USE`);
- the last open option cannot be closed (`LAST_PAYMENT_METHOD`);
- a booking cannot be written with a closed option or an amount outside its limits (`PAYMENT_METHOD_DISABLED`,
  `PAYMENT_AMOUNT_OUT_OF_RANGE`), and a reservation always has a time to be paid by (`PAY_BY_REQUIRED`);
- the settings are checked against their JSON contract (`sys.json_contract`).

| Setting | Option | Default | Meaning |
|---|---|---|---|
| `hold_hours` | `PAY_LATER` | 24 | how long the seats stay reserved |
| `cutoff_minutes` | `PAY_LATER` | 120 | reservations stop, and must be paid, this long before departure |
| `max_open` | `PAY_LATER` | 2 | unpaid reservations one passenger may hold |
| `hold_minutes` | `CARD`, `INSTALLMENT` | 20, 30 | time to finish on the provider's page |
| `hold_hours`, `cutoff_hours` | `FINANCING` | 72, 48 | time for the financing company to approve |
| `trip_types` | `FINANCING` | `PILGRIMAGE`, `TOURISM` | the kinds of trip financing covers (empty: every trip) |
| `default_credit_limit` | `CASH_COUNTER` | 1,000,000 SYP | cash a carrier may owe before its cash sales stop |
| minimum amount | `FINANCING` | 1,000,000 SYP | financing is for high-value trips |

Carriers choose the kind of trip (scheduled, international, extra, pilgrimage, tour) when they create it.

## 2. Reservations

A reserved booking (`PAY_LATER`, `CARD`, `INSTALLMENT`, `FINANCING`) is written as `PENDING_PAYMENT` with its seats
sold and its tickets on `HOLD`. A ticket on hold is never valid for boarding: it has no QR code, the driver's boarding
scan refuses it, the driver app's list leaves it out, and official manifests list only issued and boarded tickets (the
carrier's own passenger list shows it as reserved). Nothing is allocated or posted to the ledger until the money arrives.

- **Paid at the counter** (`PAY_LATER`): the passenger gives the booking reference; the counter collects the cash and
  the tickets are issued at once.
- **Paid through a provider**: the passenger is sent to the provider's page; the provider's signed notification credits
  the passenger's wallet from the gateway clearing account and pays the booking from it in the same transaction. If the
  notice arrives after the reservation lapsed, the money stays in the wallet and finance can refund it to its source.
- **Not paid in time**: the worker runs `sales.expire_reservations()` every minute; the booking becomes `EXPIRED`, its
  tickets are cancelled, its seats return to sale and any pending payment for it is closed. Completing a trip also
  expires its unpaid reservations.
- **Cancelled by the passenger** before paying: the seats return to sale; nothing is refunded because nothing was paid.

## 3. Cash at the counter

Counter staff (role template `CARRIER_COUNTER`, permission `sale.cash`; carrier owners too) work in
**Carrier portal > Counter sales**: sell the carrier's own trips for cash, collect pay-later reservations, cancel and
give cash back, print tickets, and count the drawer with the day report per seller.

The ledger records each cash sale like any other sale, paid from the carrier's cash wallet (`CASH_COLLECT`, exact
balance, allowed to go negative): the price goes to escrow and is allocated and released on trip completion as usual.
The negative balance of the cash wallet is the cash the carrier holds for the platform (`fin.cash_owed`).

- **Credit limit**: a cash sale or collection that would take the debt past the carrier's limit is refused
  (`CASH_LIMIT_REACHED`). Finance sets a limit per carrier (permission `cash.credit_limit`); otherwise the default of the
  `CASH_COUNTER` option applies (`fin.cash_limit`).
- **Set-off**: when a trip completes, and before every withdrawal, the carrier's spendable earnings pay the debt first
  (`CASH_NETTING`: debit the carrier wallet, credit the cash wallet). Money held for a pending withdrawal is left alone.
- **Remittance**: what is still owed is paid to the platform (bank deposit, the platform's cash office or an exchange
  house). One finance officer records it, a second confirms it (`cash.remittance`, four eyes enforced in the database);
  the confirmation posts `CASH_REMITTANCE` (debit bank clearing, credit the cash wallet). A rejected or confirmed
  remittance does not change.
- **Refunds**: a booking paid in cash is refunded in cash at the counter, which lowers the debt. A passenger cancels a
  cash-paid booking online only while the wallet option is open (the refund then goes to the wallet); otherwise the
  answer is `CANCEL_AT_COUNTER`. Counters do not refund bookings paid online.

**Payments > Counter cash** shows what each carrier owes, its limit and pending remittances.

## 4. Connecting a provider

Instalment and financing providers use the same hosted-page contract as card gateways
(`backend/app/modules/payments/adapters.py`): the platform creates a checkout session (`POST /v1/checkout-sessions` with
`product` = `CARD`, `INSTALLMENT` or `FINANCING`), the payer finishes on the provider's page, and the provider sends a
notification signed with HMAC-SHA256 (`X-Masslak-Signature`) to `/api/payments/notify/{code}`. A provider whose API
differs gets its own adapter class with the same four operations (start, verify, confirm, refund).

To open card payment at checkout, for example:

1. Contract the gateway; put its keys in the environment (`MASSLAK_PSP_CARD_SECRET`, `MASSLAK_PSP_CARD_KEY`).
2. In **Payments > Payment methods**, set the card provider's address and merchant id, and switch it on.
3. In **Payments > Booking payment options**, open `CARD` with a reason.

The placeholders `INSTALMENTS` and `TRAVEL_FINANCE` follow the same steps. Without an address and in the sandbox, the
built-in simulator stands in for the provider.

## 5. Interfaces

| Who | Endpoint |
|---|---|
| Passenger | `GET /api/payments/booking-options`; `POST /api/bookings` with `pay_with`; `POST /api/bookings/{ref}/payments` |
| Counter | `/api/carrier/counter/` `dashboard`, `holds`, `bookings` (sell, list, detail), `bookings/{ref}/collect`, `bookings/{ref}/cancel`, `tickets/{uid}/qr`, `report` |
| Finance | `GET` and `PUT /api/admin/payment-methods`; `/api/admin/cash/` `positions`, `limits/{company}`, `remittances`, `remittances/{id}/decide` |

Events: `booking.reserved` (in-app and e-mail to the passenger, or a text to the traveller's mobile for counter sales)
and `booking.confirmed` when a reservation is paid.

## 6. Tests

- Database: 17 checks in `db/tests/run_tests.sql` (switches, provider rules, booking rules, expiry, cash owed and
  limits, remittance four eyes, privileges).
- API: `backend/tests/test_payment_options.py` (14 tests): switches and permissions, cash sale and credit limit, cash
  refund, pay later reserve and collect, open-reservation limit, expiry, instalments through the simulated provider,
  financing minimum and trip kinds, remittance four eyes, set-off on trip completion with a balanced ledger.
