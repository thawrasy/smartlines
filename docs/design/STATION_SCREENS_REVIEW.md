# Design review of the boarding-station screens (October 2026)

Readiness register item C6. This review covers the screens built in steps 3 to 5 of the boarding stations
(`docs/operations/BOARDING_STATIONS.md`, files 1105 to 1112) and the screens of the gaps closed with them. It was done
on a running system with a realistic station day, before testing with real users
([STATION_USER_TESTING.md](STATION_USER_TESTING.md)). The clear defects were fixed in the same change (file 1113, API,
web). The items that need the owner's decision, and those left for later, are listed at the end.

## 1. Scope and method

| Screen | Who uses it | Address |
| --- | --- | --- |
| Station portal: overview, trips, check-in and boarding pass, boarding at the bay, counter sales, a sold booking | Clerks of an operating company | `/station/*` |
| Departure board | Passengers in the station hall (TV), and on a phone | `/board/<station uid>` |
| Boarding stations | Carrier operations | `/carrier/stations` |
| Boarding stations | Platform operations | `/admin/boarding` |
| Loyalty partners | Platform finance | `/admin/payments` (loyalty tab) |
| Wallet and points | Passengers | `/wallet` |

The day was built through the API: an operating company onboarded by the platform, boarding switched on at Damascus
Central Station with its screens, two counters and four bays, the three rights given by the carrier, five departures
(one boarding, one with check-in open, one without a bay, one departed and one cancelled), bookings, check-ins, one
boarding and one cash sale at the counter. Every screen was captured in Arabic and English, on a desktop (1366 × 900)
and a phone (390 × 844), and the board also on a 1920 × 1080 screen.

Each screen was checked against:

- the usability heuristics (status visible, match with the station's work, error prevention and recovery, recognition
  rather than recall, consistency);
- counter ergonomics: a barcode scanner that ends with Enter, one passenger every 20 to 30 seconds, a printed pass;
- WCAG 2.1 AA with axe-core, through the same browser checks CI runs on every portal (`frontend/e2e/ui-checks.mjs`);
- right-to-left layout and language: direction, digits, names, no sideways scrolling;
- the approved decisions: the photo stays off at the counter; the ticket's signed code exists only from three hours
  before departure.

Severity: **critical** blocks a task or breaks a rule; **high** causes errors or slows every passenger; **medium**
confuses or looks wrong; **low** is polish.

## 2. Findings

| # | Screen | Finding | Severity | Status |
| --- | --- | --- | --- | --- |
| F1 | Boarding pass | The printed pass had no code. A passenger holding only paper could not be scanned at the bay or by the driver. | Critical | Fixed |
| F2 | Ticket printed at a counter or an agency | The ticket showed the rotating code (valid at most three minutes) with "the code changes every 90 seconds". On paper it was useless. | Critical | Fixed; owner decision O1 |
| F3 | Check-in | The identity check came after the scan field and blocked the button. A scan (with its Enter) did nothing while the box was not ticked, with no message. | High | Fixed |
| F4 | Station trips | No destination column. The status showed the sale state ("open for sale"), not the check-in. Three days were mixed in one list, with a strong "Sell" button on every row. Trips ending at the station were listed. | High | Fixed |
| F5 | Station portal, board, platform and carrier screens, pass | Station and city names in English inside the Arabic interface ("Aleppo", "via Homs · Hama", "Damascus Central Station"). | High | Fixed |
| F6 | Station overview | Two missing translations shown as raw keys (`st.usable`). | High | Fixed |
| F7 | Sales, sold booking, board | Accessibility: an unlabelled date field, an unlabelled field for the verification link, low contrast on cancelled and departed rows (4.32:1). The station portal and the board were outside the CI checks, because the portal needs a second factor. | High | Fixed; now in CI |
| F8 | Check-in | A ticket checked in again was said only in a three-second message that covered the pass. | Medium | Fixed |
| F9 | Board | Times followed the browser's language (Arabic-Indic digits next to Latin trip numbers). A network failure replaced the whole board with "not available". | Medium | Fixed |
| F10 | Loyalty partners (finance) | Raw codes (`REST_STOP`, `MONTHLY`), and the currency shown twice ("0 SYP SYP"), also in the payment confirmation. | Medium | Fixed |
| F11 | All screens naming stations | The shared helper called a border crossing a city station ("SY-DAM-X901" became "Damascus Station 901"). | Medium | Fixed |
| F12 | Board on a phone | The page scrolled sideways in English. | Medium | Fixed |
| F13 | Station overview | A station known only from its counters was named by its code twice. Nothing asked the clerk to choose a counter, although check-in and sales need one. | Medium | Fixed |
| F14 | Platform and carrier tables on a phone | Station codes broke in the middle ("SY-ALP-" / "C001"). | Low | Fixed |
| F15 | Ticket | The fare class showed its code (`STANDARD`). | Low | Fixed |
| L1 | Board | One language at a time; Syrian stations usually alternate Arabic and English. | Low | Owner decision O2 |
| L2 | Station trips, carrier rights on a phone | Tables scroll sideways; the revoke action is off screen. The counter works on a desktop, so cards for phones come later. | Low | Later |
| L3 | Data | Station names are kept in English only; crossings (class X) keep their English name in Arabic. Demo data: two loyalty partners named after the platform and its administrator; Nasib crossing recorded under Damascus. | Low | Later (data) |
| L4 | Bay | No sound or vibration for the scan result. | Low | User tests |
| L5 | Boarding pass | Layout not yet tried on an 80 mm receipt printer. | Low | User tests |

## 3. What changed

**Paper carries a code that scans (F1, F2).** The boarding pass and a ticket printed at a counter or an agency now
carry the ticket's signed credential (T2). It does not change, so paper works, and the bay and the driver's app already
accept it. It stays within the approved rule: the credential is issued only from the hours before departure the
platform sets (three in production). A pass or a ticket printed earlier shows no code and says from when it is ready;
the passenger prints it again then, or checks in at a station counter with the ticket number and booking reference.
The rotating code stays on the passenger's own phone.

- `GET /api/station/tickets/{uid}/offline` and `GET /api/carrier/counter/tickets/{uid}/offline` (the agency already
  had one); the check-in and `GET /api/station/passes/{pass_no}` return `credential`, or `credential_opens_at` before
  the window.
- `brd.boarding_pass` names its ticket (`ticket_uid`, file 1113).

**The counter's trips (F4).** `brd.station_trips` gives the destination (last stop and its city) and the check-in
window of the station (`checkin_opens_at`, `checkin_closes_at`), and no longer lists trips that end at the station
(file 1113). The screen groups trips by day (today, tomorrow, then the date), shows the destination in bold and the
check-in state ("opens at 20:17", "open until 20:27", "closed"; "boarding" once boarding starts). "Sell" is an
outlined button.

**Check-in (F3, F8).** The identity check comes first and is larger. A scan without it keeps the scanned code and asks
for the check in a visible message, with focus on the box. The button stays available. A ticket checked in again shows
a notice above the pass that stays.

**Names and language (F5, F6, F9, F11, F13, F15).** Cities and central stations are named from their codes in the
screen's language; the board gets the city codes of the stops on the way (`via_codes`, file 1113). Times on the board
use the interface's locale with Latin digits. Crossings keep their own name. Missing translations were added.

**Board (F9, F12, F7).** When the connection drops, the last board stays with "connection lost · last updated hh:mm".
On a phone the trip number gives way. Departed rows are greyed with a colour that keeps a 4.5:1 contrast, rather than
with transparency.

**Finance (F10).** Partner types and cycles are translated; amounts carry their currency once.

**Checks (F7).** `backend/tests/ui_station_setup.py` prepares a station counter and a clerk's session after the
end-to-end tests. `ui-checks.mjs` then checks the station portal and the board in both languages, on both screen
sizes, with the other portals: 28 more page views, all without a serious or critical finding.

Files: `db/schema/1113_station_screens_review.sql`; `backend/app/modules/boarding/api.py`, `station_sales.py`,
`cash/api.py`; `frontend/src/pages/station/Station.tsx`, `DepartureBoard.tsx`, `passenger/Booking.tsx`,
`finance/Partners.tsx`, `admin/Boarding.tsx`, `carrier/StationOps.tsx`, `i18n/*`, `theme.css`;
`frontend/e2e/ui-checks.mjs`; tests in `db/tests/run_tests.sql` and `backend/tests/test_station_*.py`,
`test_payment_options.py`.

## 4. Decisions for the owner

**O1. Paper tickets sold more than three hours before departure, away from a boarding station.** A ticket bought at a
carrier's office a day ahead has no code when it is printed. Today the passenger prints it again within three hours,
or checks in at a station counter. Options:

1. Keep it as now. Nothing changes, but passengers must come back to an office or a station.
2. Let the driver's app board a passenger by ticket number and booking reference, against the trip's manifest, which the
   app already holds offline. *Recommended.* It keeps the approved rule and needs no new code on paper.
3. Issue a fixed signed code on paper from the sale, tied to the trip and used once. It is the simplest for
   passengers, but it changes the approved three-hour rule (a copy works until first use) and needs the owner's approval.

**O2. Languages of the departure board.** Arabic only, or alternate Arabic and English every 10 seconds (the usual
practice in Syrian stations and airports). The second is recommended.

## 5. Next

- Test with real users at the pilot station on the staging environment, with the station's own devices
  ([STATION_USER_TESTING.md](STATION_USER_TESTING.md)), before the go/no-go of 29 December 2026.
- After the owner's answers, build O1 (option 2) in the driver's app and O2 on the board.
- Later items L2 and L3 with the next screen work and the initial data load.
