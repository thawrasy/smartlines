# Connections across carriers, and changing a booking to another trip

Owner's request, October 2026. Built in migration 1130 (`db/schema/1130_connections.sql`), the module
`backend/app/modules/sales/connections.py` and the journeys (`journeys.py`, kind `CONNECTION`).

## What the owner asked

In the booking portal, book trips that are not direct, on several carriers. For example, from Daraa to Aleppo where no
trip runs direct: carrier A from Daraa to Damascus or Homs, and the system offers trips of other carriers (or the same
carrier) leaving from Damascus or Homs to Aleppo at a nearby time or the same time. Such a booking may need flexible
trips: a traveller who misses the second trip uses the ticket by changing the booking to another trip, as the carrier's
policy says. The traveller is warned of the risks.

## How a traveller books a connection

1. **Search.** Under the trips of the day, the results offer the connections through a city on the way: shown at once
   when no trip runs, and with a button otherwise. Each connection shows both trips, their carriers, the change (city,
   station, minutes; another station of the city is marked), the total price, and what each carrier does when a
   traveller misses its trip.
2. **Which connections.** The first trip boards in the origin city on the day and arrives in a city that is neither end.
   It is not a trip that goes on to the destination itself, which is a direct trip. The second trip leaves that city for
   the destination:
   - at least `journey.connections.min_minutes` after the first arrives, if it leaves from the same station (30 by
     default);
   - at least `min_minutes_station_change` after it, if it leaves from another station of the city (60);
   - and at most `max_minutes` after it (240).

   A carrier that keeps its trips out of connections is not offered. The earliest arrival comes first, then the lower
   price, up to 20 connections.
3. **Checkout.** The journey page shows both trips, the change time between them and each carrier's policy. Each trip
   takes its own fare. Where the platform requires it (`journey.connections.require_flexible`, on by default), a later
   trip takes a fare that may be changed (Standard or Flexible), unless its carrier changes a missed trip free after a
   late first trip; a Saver fare there is refused (`CONNECTION_NEEDS_FLEX`).
4. **Risks.** Before booking, the traveller reads and accepts the risks:
   - each trip is a booking of its own carrier, with that carrier's rules, and no carrier answers for the other's trip;
   - a late first trip does not hold the second;
   - a missed trip is changed only as its carrier's policy says;
   - the traveller changes vehicles with their luggage in the time shown.

   The server refuses a connection without that acceptance (`CONNECTION_RISKS_NOT_ACCEPTED`). Each booking records when
   it was given (`sales.booking.risk_ack_at`), and the database refuses a connection's booking without it
   (`booking_connection_ack_ck`).
5. **Result.** One booking per trip, each with its carrier, tickets, rules, refunds and e-invoice, all of one journey of
   kind `CONNECTION`. All are booked in one transaction or none is. The server checks the order, the change times
   (`CONNECTION_TOO_SHORT`, `CONNECTION_TOO_LONG`) and that each trip leaves the city where the one before arrives
   (`CONNECTION_BREAK`).

## Each carrier's policy

The carrier sets it on its routes page (`ops.carrier_connection_policy`, `PUT /api/carrier/connection-policy`,
permission `trip.publish`):

| Setting | Meaning |
|---|---|
| Offered in connections | Whether its trips appear in connections (yes by default) |
| `FREE_CHANGE` | A traveller who misses its trip because the first trip of the connection arrived late (or was cancelled) travels free on another of its trips |
| `FARE_RULES` (default) | A missed trip is changed under the fare's rules: a changeable fare, its change fee (Standard 10 %, Flexible free) |
| `NONE` | A missed trip is not changed; the ticket is lost |
| Change window | Hours after the departure of the missed trip during which a change is accepted (1 to 168, 24 by default) |
| Note | Shown to travellers with the carrier's trips in connections |

The policy is public: search, the trip page and the booking show it.

## Changing a booking to another trip

The passenger opens the booking and chooses *Change trip* (`GET /api/bookings/{ref}/change-options`, then
`POST /api/bookings/{ref}/change`). The change goes to another trip of the same carrier between the same cities,
leaving in the next three days.

- **Before departure:** the fare's rules apply. A Saver fare is refused (`NOT_CHANGEABLE`); Standard pays its change fee
  of 10 % of the fares; Flexible changes free.
- **After the trip left without the traveller** (trip boarding past its time, or departed; tickets still issued):
  - the carrier's policy applies, within its window (`CHANGE_WINDOW_CLOSED` after it);
  - `NONE` refuses (`CHANGE_NOT_ALLOWED`);
  - `FREE_CHANGE` changes free when the trip before it in the connection arrived too late: actual arrival later than
    the departure less the minimum change time, or cancelled (`sales.missed_connection`);
  - otherwise the fare's rules apply.
- **A late first trip known before departure** (cancelled, or arrived late) also gives the free change where the
  carrier offers it.
- **How it is done:** in one transaction.
  1. The old booking is cancelled (reason `CHANGED`). Its fares come back to the wallet, less the fee, which stays with
     the carrier.
  2. The new trip is booked and paid from the same wallet, with the same travellers (their documents carried over),
     the same fare and seats side by side.
  3. The new booking keeps the journey, its leg and the acceptance of the risks, and names the booking it replaced
     (`changed_from_id`).
  4. `sales.booking_change` records both bookings, the reason (`MISSED_CONNECTION` or `CUSTOMER`), whether the trip was
     missed and the first trip late, the basis (`FREE_CHANGE` or `FARE_RULES`), the fee, what came back and what was
     paid.

  If the wallet cannot pay the new trip, nothing changes. The same request sent twice answers with the same change.
- **Who changes:** the booker, for a booking paid from the wallet. A booking of an agency, of a charter, paid from a
  family's money or not from the wallet is changed by whoever paid it (`CHANGE_NOT_AVAILABLE`).
- **The booking page** shows the booking it replaced and the one that replaced it. A connection's trip carries a
  reminder of what to do if the trip before is late.

### A limit to know

When the carrier completes the missed trip, its escrow is released and its tickets not travelled are closed as no-show.
From then on the booking can no longer be changed. A traveller who missed a trip changes it before the carrier closes
that trip, which is usually on arrival. Moving this point is a decision for the owner: for example, holding the escrow
of a connection's missed tickets until the change window ends.

## The platform's settings

On *Booking rules → Connections* (`/admin/booking?tab=connections`, permission `policy.matrix`;
`sales.set_connection_settings`, platform only):

| Setting | Default | Bounds |
|---|---|---|
| `journey.connections.enabled` | on | |
| `journey.connections.min_minutes` | 30 | 10 to 240 |
| `journey.connections.min_minutes_station_change` | 60 | at least the above, up to 360 |
| `journey.connections.max_minutes` | 240 | at least the above, up to 720 |
| `journey.connections.require_flexible` | on | |

## Demo data

The seed adds **Demo Carrier B** (`owner@carrierb.test`, code DCB / DB) with route DRA-DAM leaving Daraa at 05:30, 08:00
and 13:00 (90 minutes). Its trips reach Damascus Central Station 30 minutes before Demo Carrier A's trips to Aleppo
(07:30, 10:00, 15:00). Daraa to Aleppo has no direct trip, so search offers these connections. Carrier B's policy is
`FREE_CHANGE`; Carrier A keeps the default `FARE_RULES`.

## Interfaces

| Interface | Who |
|---|---|
| `GET /api/trips/connections?origin&destination&on&passengers` | anyone |
| `POST /api/journeys` with `kind: "CONNECTION"`, `accept_risks: true`, `legs[].fare_brand` (also `/api/agency/journeys`) | passenger, agency |
| `GET /api/bookings/{ref}/change-options`, `POST /api/bookings/{ref}/change {trip_uid, from_seq, to_seq, idempotency_key}` | the booker |
| `GET /api/carrier/connection-policy`, `PUT` (trip.publish) | carrier |
| `GET /api/admin/connections/settings`, `PUT` (policy.matrix) | platform |
| `connection_policy` on `GET /api/trips/{uid}`; `changed_from` and `changed_to` on a booking | anyone, booker |

## Tests

- **Database** (`db/tests/run_tests.sql`, "Connections (1130)"): the defaults; settings are the platform's own; bounds;
  a carrier sets its own policy only; the acceptance is required on a connection's booking; a free change has no fee;
  a change is never rewritten.
- **API** (`backend/tests/test_connections.py`):
  - search across carriers where no trip runs direct;
  - risks to accept, a changeable later trip, trips too far apart refused;
  - a missed connection after a late first trip changed free, with the wallet, the records and a replay checked;
  - the `NONE` policy;
  - a change before departure under the fare's rules, the fee, another carrier's trip refused, a Saver fare refused;
  - the platform's settings and a carrier that keeps out of connections.
- **Screens:** the web results for Daraa to Aleppo and the connection checkout, in both languages, on phone and desktop
  (`frontend/e2e/ui-checks.mjs`); the mobile results, journey and booking screens.
