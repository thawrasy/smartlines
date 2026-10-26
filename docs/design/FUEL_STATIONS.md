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

## What is built (1180)

- **Database** (`db/schema/1180_fuel_stations.sql`, phase 9, behind the `service_partners` switch): FUEL portal and
  FUEL_COMPANY company type with the `fuel.manage` / `fuel.attend` rights; prepaid accounts held with the fuel company
  (`ptn.fuel_account`) with an append-only entry book whose trigger moves the balance and never lets it go below zero;
  vehicle cards with a budget per day, week or month (amount and/or litres); NFC tags stored only as a hash; the fill
  (`ptn.fuel_fill`) requires the meter photo uploaded by the attendant and checks amount against price, tank size,
  odometer going back, consumption and distance. Any finding holds the fill until the carrier decides it; the fuel
  company can give a fill back with a REVERSAL entry. Every write goes through SECURITY DEFINER functions.
- **API** (`backend/app/modules/fuel/api.py`): fuel company portal (`/api/fuel`: overview, attendants, prices, accounts and
  top-ups, fills and photos, reversals, findings, and the pump: identify, bind tag, fill); carrier fuel
  (`/api/carrier/fuel`: accounts, cards and budgets, block, unbind, pump code, fills, consumption, findings); the driver's
  pump code (`/api/driver/fuel`); platform onboarding of fuel companies and stations (`/api/admin/fuel`).
- **Pump code**: `F1` + base32 of the card id, expiry and an HMAC; life from the `fuel.checks.code_seconds` setting.
- **Notice**: `fuel.filled` to the owners of the vehicle's company, with the balance and the budget left; also an
  integration event for carrier and internal clients.
- **Screens**: fuel portal (home, pump with Web NFC, QR camera, typed card number, meter photo; fills, findings,
  accounts, stations, people), carrier fuel page, driver code page, platform fuel page; English and Arabic.
- **Tests**: 24 database checks and `backend/tests/test_fuel_stations.py` (the whole flow end to end).

## Hard to cheat, and sold as a service (1181, owner's note of 26 October 2026)

**The vehicle is present.** The platform registers every NFC tag it hands to carriers (`ptn.fuel_tag`, the serial kept
as a hash only) and issues tags to a carrier; the carrier binds a tag to its vehicle's card through the platform (read
by the phone, Web NFC) before sticking it on. With `registered_tags_only` a tag the platform did not issue is refused,
and a tag reported lost never identifies a vehicle again. A secure tag (NTAG 424 DNA, Secure Unique NFC per NXP AN12196)
writes a fresh signed message on every tap: its serial and a counter, encrypted with the shared meta key, and a MAC with a
key drawn from the tag's serial and `MASSLAK_FUEL_TAG_KEY`. A copied tag cannot sign, a recorded message replays a
counter already seen (`FUEL_TAG_REPLAY`), and a secure tag read by its serial only is refused (`FUEL_TAG_SECURE`). The
programming bench prints the keys with `python -m app.tools.fuel_tag_keys`.

**The system thinks before each fill.** Each identification opens a challenge (`ptn.fuel_challenge`) the fill must answer
within `challenge_minutes`, once. Its risk points come from how the vehicle was identified (typed card number 40, app code
15, plain tag 10, secure tag 0), a fill on the same card within `refill_hours` (30), open or confirmed anomalies on the
vehicle (20), an attendant with one fill in ten flagged (20), and a station without a pump controller (10); `sample_pct`
draws fills at random. From the points (or always, by setting) the challenge asks for the pump's QR sticker and for the
odometer's photo with its reading.

**The pump is real.** Each pump carries a signed QR sticker beside its meter ("FP1" + pump, sticker version and HMAC),
printed from the fuel company's portal; a new sticker raises the version and the old one stops working. When the station's
pump controller (forecourt system) reports its deliveries (`POST /api/pump/deliveries` with the station's key), each
fill is matched with the pump's own litres and amount: a fill the pump has not reported waits (`PUMP_UNCONFIRMED`) and is
completed by the matching delivery; one the pump delivered differently is held (`PUMP_MISMATCH`).

**The photo is live.** The pump app has no file picker and no gallery: it draws a frame of the live camera and sends it as
a JPEG with no metadata. The server refuses a picture carrying a camera app's metadata (`FUEL_PHOTO_NOT_LIVE`) and keeps a
64-bit difference hash of each meter photo; a near match with a photo of the last `photo_dup_days` at the station or of the
card opens `PHOTO_REUSED` and holds the fill. The owner sees the meter's and the odometer's photos and can question a fill
(`OWNER_QUERY`), which the fuel company answers.

**The allowance.** A card's budget renews by day, week, month, quarter or year (the renewal date is shown), may end on a
date (`valid_until`), and its owner may pause it; a paused card keeps its tag and vehicle.

**The service sold.** A carrier subscribes vehicles by the week, month, quarter or year (`ptn.fuel_subscription`); the
price per vehicle comes from the platform's list (setting `fuel.subscription`) or is set when the platform records the
advance payment, and a vehicle fills only while a paid subscription covers it (`required`). The platform's commission on
the carrier's fills is agreed with the subscription, and on each fuel company's fills in its terms
(`ptn.fuel_company_terms`); each fill records both as due (`ptn.fuel_commission`), a fill given back voids them, and the
platform's page totals them by month for its invoices. Fuel money itself stays with the fuel company.

**What still rests on people.** A determined attendant could photograph a printed copy of a sticker or a screen showing a
meter; the random checks, the pump controller and the owner's review of the photos are what catch that. Reading the
digits of the meter and the odometer from the photos (OCR) is not built: the figures are compared with the pump
controller instead, where the station has one.

## Not built yet

- Station mode in the native mobile app and the pump code screen in the mobile driver app (the web pages work on Android
  Chrome, which offers Web NFC; an iPhone reads the QR code but not NFC from a web page).
- Reading the meter's and the odometer's digits from the photos (OCR), and a trained check for photos of screens or prints.
- Private subscribers without a fleet company.
- Settlement statements between the platform and fuel companies (the platform holds no fuel money today).
- Findings for fills outside the vehicle's route or working hours.
