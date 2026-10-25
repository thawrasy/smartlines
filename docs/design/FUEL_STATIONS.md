# Fuel stations (owner's note, 25 October 2026)

A fuel station joins the platform like any partner: it is defined with its full details, gets its own app and a wallet,
and every fill is a ledger entry. Vehicles are known by an NFC card or by the driver's or subscriber's app. Money is
paid in advance, each vehicle has a budget, the owner is told of every fill, and the pump's meter is photographed so the
amount can be checked. A company that owns stations gets a portal over all of them; carriers, taxis and rental
companies follow their vehicles' fuel through their own portals.

## What the schema already holds (study, 1014)

The partner model was planned and stays the base, not a parallel one:

* `ptn.partner` (type `FUEL`): the station, its place and geofence, licence, hours, compliance state;
  `ptn.partner_contract`: commission, settlement cycle and credit terms, approved by a second person;
* `ptn.station_employee`: attendants, cashiers and managers of the station;
* `ptn.fuel_price`: the price of each fuel type from a time on;
* `ptn.fuel_card`: a card per vehicle or driver with daily and monthly limits and allowed fuel types;
* `ptn.fuel_session`: one fill, from opening at the pump to completion, with the attendant, vehicle, driver and trip;
* `ptn.odometer_reading`: the odometer with its photo, read value and the two confirmations;
* `ptn.partner_sale`: the sale with litres, unit price, amount, method and its ledger entry; `ptn.fuel_anomaly`: what
  looks wrong.

## What is added

1. **Station chains**: a company of type `FUEL_COMPANY` that owns several stations, with its portal (stations, prices,
   staff, fills, settlements, disputes).
2. **The vehicle's fuel account**: money is paid into it in advance (by the carrier, the rental company, the taxi
   owner or a private subscriber); a budget per vehicle as an amount, litres, or both, per day, week or month; the
   fill stops at the budget. Built on the wallet and the ledger, with the platform holding nothing in the cash-only
   phase (the station's own prepaid balance, 1157).
3. **Identifying the vehicle**: the card's NFC tag holds only a random identifier (no data), read by the station's app;
   or the driver's or subscriber's app shows a short-lived code at the pump (the ticket QR mechanism). A card is tied
   to one vehicle; a lost card is blocked at once from the owner's portal.
4. **The fill, step by step** in the station app: identify the vehicle, the budget left is shown, the attendant fills,
   then photographs the pump's meter (amount and litres) and enters the figures; the photo is kept with the sale; the
   figures are compared with the price in force (litres x price = amount) and with the vehicle's tank size and the
   kilometres since the last fill; anything outside the limits opens an anomaly for review and the sale is held.
5. **Notices**: the owner (and the driver) are told of every fill: station, litres, amount, budget left, the photo.
6. **Monitoring**: carriers, taxi and rental companies see each vehicle's litres, amounts, litres per 100 km, fills
   outside their routes or hours, and anomalies; exports and reports.

## Build order

1. Database: fuel company type and portal, vehicle fuel accounts and budgets, NFC cards, the meter photo and checks on
   the sale, anomaly rules as settings; DB checks.
2. API: station app (identify, fill, photo, close), owner portals (accounts, budgets, cards, fills), fuel company
   portal, platform review of anomalies and contracts.
3. Screens: web portals; the station mode of the mobile app (NFC and camera); notices.
4. Tests, docs, a pilot with one station.
