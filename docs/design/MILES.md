# The miles programme

Owner's note 19 (wave 6), migration `1166_miles.sql`. It builds on the loyalty points of `1103` and the partner
agreements of `1107`.

## What the programme is

* **Name and unit** are settings of the platform, in Arabic and English (`pricing.loyalty_program.name`, `name_ar`,
  `unit_en`, `unit_ar`): Masslak Miles, miles by default. Expiry is kept in months.
* **Tiers** keep their thresholds; each tier may carry a multiplier on chart miles (`benefits.multiplier`, 1 when absent).

## Earning

* **`pricing.miles_chart`**: miles per pair of stations, in either direction, optionally on a route of the network. One
  active row per pair; a new value retires the old one.
* When a carrier completes a trip, each boarded ticket between two stations of the chart earns their miles, times the
  member's tier multiplier (`pricing.earn_points_for_trip`, one ledger entry per booking and programme, idempotent).
* A booking the chart does not cover earns by the amount rules, as before.

## Award tickets

* **`pricing.award_fare`**: miles plus a fee and a reduced amount between two stations, for one carrier or any.
* They are shown to members now. Redeeming waits for the setting **`loyalty.award_redemption`** (off): it needs paying
  the carrier, so it opens with the money phase or an agreement with the carrier.

## Partners and the corner

* Partner types: carriers, banks, restaurants, rest stops, shops (and the earlier fuel, retail, airline, travel, other).
* A partner is **active only with its contract number** (`PARTNER_CONTRACT_REQUIRED`).
* **Partners corner** (`GET /api/loyalty/corner`): active partners with a contract, their offer note and their
  agreement's rate.
* A promoted partner is shown first with the label **Promoted**, only while **`loyalty.promoted_display`** is on (off
  in the first phase).

## API and screens

* Members: `GET /api/loyalty/programme`, `/miles?from=&to=`, `/corner`, `/awards`; the corner and the award tickets on
  the wallet page.
* Platform (`loyalty.manage`): `/api/admin/miles` (programme, tiers, chart, award tickets, partners, switches); the
  **Miles programme** page at `/admin/miles`.

## Checks

* `backend/tests/test_miles.py`: name and unit, chart earning in either direction, award tickets shown but not redeemable,
  contract required, promoted label only while shown.
* `db/tests/run_tests.sql` (1166): chart pairs, one row per pair, tier multiplier default, switches off, Arabic name,
  contract required, new partner types.
