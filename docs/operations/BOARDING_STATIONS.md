# Boarding stations and operating companies (requirements and build status)

Status (October 2026): requirements recorded from the owner's answers. Build step 1 is in place (migration 1097 and its API):
the platform settings, each station's own switch, the numbering of counters and bays, and the optional reference fields.
Step 2 is in place (migrations 1098 and 1099 and their API): the rights an operating company holds at a station, given by
the carrier or by the platform, the decision whether it may act, and the operating company's own portal (`STATION`, the
owner's option A). Step 3 is in place (migration 1105 and its API): the counter check, the boarding pass with the bay,
and the boarding at the bay by station staff, under the rights of step 2, with the check-in window and the required
references applied (section 8b). Everything is off, or empty, at launch, and nothing in the booking, the boarding or the
ticket changes until the platform switches a station on. The screens (step 4) and the counter photo (step 5) are not
built (section 9).

## 1. What it is

Passengers are processed at a boarding station, as at an airport: a counter check, then boarding onto the bus. An operating
company can run the station counters and the boarding procedures on behalf of the carrier. Each operating company has its
own counter or counters at the station. The carrier sells and transports; the operating company processes the passengers.

Typical sequence, per passenger and ticket:

1. Arrival at the station; the passenger goes to the counter of the operating company that serves their trip.
2. Counter check: the ticket, the identity document, and the boarding photo when the platform shows it to the counter.
3. The counter issues the boarding pass and records the check-in for the ticket and the seat.
4. Boarding onto the bus: the driver or the station staff confirms the boarding scan (the existing boarding path).

## 2. Who appoints the operating company (two ways, both possible at the same time)

- **Mandated by the state.** The platform setting imposes a state-mandated operating company for the stations. The platform
  gives that company its own portal role, and the station-operation rights it needs. Carriers then grant it permissions.
- **Contracted by the carrier.** The carrier contracts an operating company to run its travel procedures at the stations.
  The carrier's portal settings name the company. The company's permissions are granted through the carrier's portal.

The two platform switches (`boarding.mode.state_mandated`, `boarding.mode.carrier_contracted`) exist and default to off. The
grants that give an operating company its rights are built (1098, section 3), and so is the operating company's own portal
(1099, section 8a). The screens for the grants, in the carrier portal and in the station portal, are not built (section 9).

## 3. Permissions the operating company receives

Permissions are granted one by one, by the carrier (for a contracted operator) or by the platform (for a state-mandated
operator), and limited to the station's work:

- create a booking and change a booking;
- issue the boarding pass;
- run the boarding procedure at the station (check-in and the boarding record).

Nothing else is granted by default. Each permission is in the activity log with the counter and the staff member.

Built in 1098, as grants (`net.station_operator_grant`):

- the three rights are `BOOKING`, `BOARDING_PASS` and `BOARDING`, named after the list above;
- a carrier grants a right for its own trips, at one station or at every station; the carrier's permission `boarding.operators`
  is held by its operations role;
- the platform grants a right to a state-mandated operator, with no carrier: it applies to every carrier's trips at the station;
- a right counts only while the station is boarding (RUNBOOKS section 32) and while the mode that gave it is on
  (`boarding.mode.carrier_contracted` for a carrier's grant, `boarding.mode.state_mandated` for the platform's);
- a grant is revoked by the party that gave it, and never changed or deleted; a carrier cannot grant to itself.

The decision is `net.operator_may(operator, carrier, station, right)`. Since 1105 the counter check asks it for
`BOARDING_PASS` and the boarding at the bay for `BOARDING` (section 8b); since 1110 the station counter's sales ask it for
`BOOKING` (section 8c). The exact list is open (section 8, item 5).

## 4. Check-in window

- Built as settings. The platform setting `boarding.checkin.opens_minutes` and `boarding.checkin.closes_minutes` (minutes
  before departure) is empty until the authorities fix it. A station can have its own window (`net.station_boarding`); a
  station's window must open before it closes, and the platform refuses the other order.
- The carrier-portal setting that overrides the platform's window is not built. Since 1105 the window is applied at
  the counter check: the station's own, or else the platform's.
- The window must also follow the rules of the competent authorities in the country, which may fix it. No trip status is
  added for it: it is a setting.

## 5. Photo at the counter

- Built in 1111 (owner's decision: not turned on from the platform until legal and legislative approvals allow showing
  it). The photo's view access has its own role for the counter, `STATION_COUNTER_AT_CHECKIN`, separate from the driver's,
  **off at launch**. Like every photo setting it changes only through the approval stages, and the change that turns it
  on is applied only with the legal approval's document number recorded (`LEGAL_BASIS_REQUIRED` otherwise); turning it
  off needs no document.
- While it is off, the counter's route `GET /api/station/tickets/{ticket_uid}/photo?station_uid=` answers
  `PHOTO_VIEW_NOT_ALLOWED` and nothing is shown. Once on, it shows the photo only for a ticket boarding at that station
  on a carrier's trip the company may check in, before departure; each view is in the activity log.

## 6. Agreement and licence references

- Each agreement between the carrier and the platform, and each licence the carrier needs, has its own reference number.
  A carrier records them in `net.operation_reference` (API: `GET`, `POST` and `POST .../retire` under `/api/carrier/references`).
- A reference is kept as the carrier gives it (1 to 60 characters). A reference is retired, never changed or deleted: the
  carrier records the corrected number and retires the old one. Only one active number per kind and licence type is allowed.
- The licence type is a code the platform will list. Until the list is decided (section 8, item 3) any code of 1 to 60
  characters is accepted.
- The fields are optional. The platform setting `boarding.references.required` lists what must be on file: `AGREEMENT`, and
  any licence type code. It is empty at launch. `GET /api/carrier/references` returns the required items that are missing.
  Since 1105 the rule is applied at the counter check: a passenger of a carrier that lacks a required reference is not
  checked in (`REFERENCES_MISSING`, naming what is missing). No purchase or trip is refused for it, and nothing is refused
  while the setting is empty.
- The numbering scheme of each licence type is not decided, so the platform does not validate the format yet (section 8,
  item 2).
- The market has no binding rules yet; regulation will follow, and the setting follows the regulation.

## 6a. Counters, bays and their numbers (owner's confirmation, October 2026)

- Each counter is numbered by the platform, per station, so that a passenger who asks the carrier about a counter gets the
  same answer. Each counter belongs to one operating company. Built in 1097: `net.open_station_gate` numbers them.
- The bus boarding bay is numbered the same way and is the bay the trip's boarding stop uses (`ops.trip_stop.gate_id`). The
  bay number is printed on the boarding pass when a bay is assigned at issue (1105). If it is not assigned at issue, the
  pass shows none and the station's screens show it later; the screens belong to step 4.
- Numbers are never reused. A closed counter or bay keeps its number, and the next one takes the next number.
- Each station is separate: its own switch, its own counter system, its own screens and its own check-in window. A station's
  counter system is `PLATFORM` (the platform runs the counters) or `EXTERNAL` (the station runs its own system, linked to the
  platform later). The platform may link a station's system instead of building it here, but the platform keeps the data and
  the interfaces so that it can be built here when the station has no system of its own.

## 7. Relation to what exists

- Carrier accounts are the `OPERATOR` portal. Every operating company, state-mandated or contracted by a carrier, signs in
  to its own portal, `STATION` (1099). A carrier gives a contracted operating company its rights from the carrier's portal.
- Trip statuses today: `PUBLISHED`, `BOARDING`, `DEPARTED`, `COMPLETED`, `CANCELLED`. The photo is shown only while the trip
  is `BOARDING` (migration 1096). The check-in window is a setting, not a status (section 4).
- The stations already exist (`net.station`, with its code, and `net.station_gate` for platforms, bays, gates and counters,
  migration 1013). Migration 1097 adds the counter's operating company, the station's boarding switch and the reference
  numbers.
- The agency (agent) route for the photo (`GET /api/agency/tickets/{uid}/photo`) follows the same pattern: built, refused
  until the platform's `AGENT` value is on and the trip is boarding.

## 8. Still open (not decided by the owner)

1. The check-in window values, which the authorities may fix. The settings exist and are empty.
2. The numbering scheme for the agreement and licence references. Counters and bays are numbered by the platform now, as
   the letter of the kind and three digits (`C001`, `B001`, `G001`, `P001`); this format is the platform's choice and can
   be changed in one function if the owner decides otherwise.
3. The list of licences the carrier's operation needs, and which of them are in the first phase.
4. The legal document that supports the counter photo, and its number: the photo stays off until it is given (1111).
5. The exact permission list, after the first operating company is appointed. Built: `boarding.manage` (platform administrator)
   and `boarding.references` (the carrier's operations role).

## 8a. Decisions taken in build step 1 (for the owner to confirm)

- The boarding settings are changed by the platform administrator directly, with the activity log, and not through the
  approval stages of the photo. The owner did not ask for stages here. If the owner wants them, the change is to route
  `net.set_boarding_setting` through the stages as the photo does (1094 to 1096).
- Station switches, counters and bays are platform tasks. The carrier's own reference numbers are the carrier's records,
  isolated by company (row-level security), and the carrier cannot change a number, only retire it.
- The station's switch and the grants belong to project phase 7, which is closed while the stations feature
  (`tracking_stations`) is off. A carrier therefore records a grant only after that feature is on, as the runbook says. The
  reference numbers belong to phase 1A, with the carrier's own records, so the stations feature does not close them.
- The operating company's own login: the owner chose option A (October 2026), built in 1099. An operating company is a company
  of its own type (`STATION_OPERATOR`), onboarded by the platform (`POST /api/admin/boarding/operating-companies`), and its
  staff sign in to the `STATION` portal only; a carrier's staff cannot open it, and the operating company opens no carrier,
  driver or agency portal. The owner of an operating company holds the station permissions only (`station.counter`), never a
  carrier's. The portal is a staff portal: it needs a second factor, like the carrier portal. Every other route of the
  platform refuses the `STATION` portal, because each one names the portals it serves.
- A grant is the carrier's own record, so the carrier decides it. The platform grants only the state-mandated operator's
  rights, and can revoke any grant.

## 8b. The counter check and the boarding pass (built in 1105)

The operating company's staff work in the `STATION` portal (owner or `station.counter`):

- `GET /api/station/trips?station_uid=` lists the trips leaving the station in the next two days of the carriers that gave
  the company a right there, with the bay, the tickets, the check-ins and the boardings.
- `POST /api/station/checkin` checks a passenger in: the ticket's code is scanned, or its number is typed with its
  booking reference, and the staff member confirms the identity document was checked. The database
  (`brd.station_checkin_ticket`) decides, in this order: the station takes boarding now (`STATION_NOT_BOARDING`); the ticket
  is valid (`TICKET_NOT_VALID`, `ALREADY_BOARDED`), boards at this station (`WRONG_STATION`) on a trip that has not left
  (`TRIP_NOT_OPEN`); the company holds the carrier's or the platform's `BOARDING_PASS` right there (`NOT_GRANTED`) and works
  at one of its own open counters at the station (`COUNTER_NOT_YOURS`); the check-in window is open, the station's own or
  else the platform's (`CHECKIN_NOT_OPEN`, `CHECKIN_CLOSED`; no window set: any time before departure); the carrier has
  the required references on file (`REFERENCES_MISSING`). A ticket checked in again gets the same pass.
- The boarding pass (`GET /api/station/passes/{pass_no}` to print it again) is numbered by the station (`<station code>-
  <8 digits>`) and prints the passenger, the seat, the trip, the stations, the departure, the counter and the bay of the
  boarding stop when one is assigned.
- `POST /api/station/passes/{pass_no}/cancel` cancels a check-in made by mistake, before boarding, with a reason; the ticket
  can be checked in again.
- `POST /api/station/board` records the boarding at the bay by station staff holding the `BOARDING` right, through the same
  boarding path as the driver's scan (the stop, the photo rule, the boarding record), and only for a ticket checked in at
  this station (`CHECKIN_REQUIRED`). The driver's own scan is unchanged.
- Each check-in keeps the station, the counter, the operating company, the carrier, the staff member and whether the
  document was checked (`brd.station_checkin`, visible to the carrier and to the operating company); every check-in,
  cancellation and boarding is in the activity log with the pass number and the counter. Check-ins are written only by
  the database functions.

The carrier's own staff are accepted by the same functions for the carrier's trips, without an operating company; no
carrier route uses them yet. Tests: the database suite (Check-in 1105) and `backend/tests/test_station_checkin.py`.

## 8c. Selling at the station counter (built in 1110; owner's decision: first release)

- A carrier gives an operating company the `BOOKING` right at a station. The company's counter staff then sell that
  carrier's tickets for trips boarding at that station, for cash, from the `STATION` portal: hold the seats, see the
  price, sell; the tickets are issued at once and printed with their codes.
- The booking is the carrier's, exactly like a sale at its own counter (1056). The operating company is its booker and
  sees the bookings it sold; the cash it takes is owed on its own cash wallet, within its cash limit, and it remits it to
  the platform like a carrier (finance's cash positions list it with the carriers).
- `brd.station_sale` records each sale with the station, the counter and the clerk, for the company and the carrier. A
  cash sale cancelled at the same counter is refunded in cash from the drawer, by the fare's rules.
- Station boarding (check-in, boarding, counter sales, departure boards) joined the first release with 1110: its tables
  left phase 7. It stays off until the platform switches boarding stations on, a station on, and a carrier grants a right.

## 8d. The screens (built in 1112, build step 4; owner's confirmation: counter screens for check-in and boarding, and the station's big screen)

- **The operating company's portal** (`/station`): where the clerk works (the station and the counter, chosen once on the
  device), the rights the carriers gave the company, the station's trips with their bays and counts, the counter check
  that prints the boarding pass with the bay, boarding at the bay, and counter sales with the day's takings and the cash
  limit. The photo is not shown at the counter (section 5).
- **The carrier's portal** (`/carrier/stations`): the rights it gives operating companies (sell, check in, board) at a
  station or at every station, the check-ins and counter sales they made on its trips in a day, and its agreement and
  licence numbers with those still missing.
- **The platform's portal** (`/admin/boarding`): every station with its boarding switch, screens, counter system,
  check-in window, counters and bays; the operating companies and their onboarding; the rights the platform gives a
  state-mandated company; and the boarding settings.
- **The station's big screen** (`/board/<station uid>`, public): every departure of the next 12 hours with its bay and its
  state (on time, check-in open, boarding, departed, cancelled) and the arrivals of the next 6 hours, refreshed every 20
  seconds, in the station's time zone. It carries no passenger data and appears only while the platform's boarding
  stations are on and the platform has switched the station's screens on (`displays`); otherwise the address answers 404.
  It is fed by `brd.station_board` (1112) from the trips and the bays the carriers assign.

## 9. Build order

1. **Done (1097).** Settings, each default off or empty: the platform switch, the two operating-company modes, the check-in
   window (platform and station), the required references. Each station's own switch and counter system. Counters and bays
   numbered by the platform. The optional reference fields. API under `/api/admin/boarding` and `/api/carrier/references`,
   with tests in the database suite and in the API suite.
2. **Done (1098, 1099).** The grants, the decision and the isolation of the grants; the `STATION` portal with the platform's
   onboarding of an operating company, and the portal's first route (`GET /api/station/overview`: the rights the company holds
   now and its counters). Not built: the screens for the grants, the carrier's window override, and the operating company's
   view of the trips and tickets of carriers that gave it rights (it comes with the counter check, step 3).
3. **Done (1105).** Counter check, boarding pass and check-in records under the granted permissions, with the activity log;
   the bay number printed on the boarding pass; the check-in window and the rule that refuses a missing required
   reference applied at the counter; the boarding at the bay by station staff (section 8b).
4. **Done (1110, 1112).** Counter screens in the operating company's portal and the carrier portal, the platform's boarding
   screen, and the station's departure board fed by the bay numbers (section 8d). Selling at the station counter
   (`BOOKING`) is built (1110, section 8c).
5. **Done (1111), off.** Photo at the counter, under its own role and only with the legal approval's document number.
