# Journeys: one way, round trip, several places, groups

Owner's request, October 2026. Built in migration 1121 (`db/schema/1121_journeys.sql`).

## What the owner asked

While booking, show: one way, round trip, a booking to several places; direct trips and trips with stops; and trips to
several places one after the other (from A to B, then on to another place), a journey planned like a tour. Tourism
companies booking group trips ask for it most.

## How a traveller books

1. **The search form** has three tabs: *One way* (as before), *Round trip* (a day to go and a day to come back) and
   *Several places* (two to six trips, each from where the last one ends by default, each with its day).
2. **The results** show one trip of the journey at a time ("Trip 2 of 3: Aleppo to Latakia, Saturday 17 October"),
   with the trips already chosen above. A trip that leaves before the chosen one arrives cannot be chosen. Every list
   can show all trips, direct trips only, or trips with stops only.
3. **The journey page** shows the chosen trips with their prices, asks for the travellers once (the same people travel
   every trip), and books everything at once, paid from the wallet or reserved to pay at the counter where the platform
   opened that option. Seats are given side by side where the trip has them.
4. **The result** is one booking per trip, as before, each with its own tickets, rules, refunds and e-invoice, all of
   the same journey; each booking shows the others.

Nothing is booked unless every trip is: no seats on one trip, sales closed, a trip in the wrong order or not enough
money in the wallet, and the whole journey is refused with the reason and the trip it concerns.

## Groups (tourism companies)

An agency books a group of up to `agency.group.max_passengers` travellers (50 by default, a platform setting) on every
trip of a journey, one way included, from its prepaid balance, within its daily limit and with its commission, as for
a single sale. The group is split into bookings of the platform's seat limit on each trip (`booking.max_seats`, four by
default), all of the same journey. A passenger's own journey has at most that many travellers with a seat, more for the
head of a larger family (`GROUP_THROUGH_AGENCY` beyond); see "Seats booked at once" below.

## Babies on a lap

A baby on an adult's lap (`with_adult`: the position of the traveller who carries them, and a date of birth) takes no
seat and travels in the booking of that traveller on every trip of the journey. Whether the carrier of each trip lets an
infant travel without a seat is checked on each trip as for a single booking; if one does not, nothing is booked. The
web checkout offers "Add a baby on a lap" only when every trip's carrier allows it.

## Seats booked at once (1122)

Owner's decision: a traveller books four seats at once; the number is the platform's to raise or lower (a regulator may
impose it); the head of a registered family books up to the family's active members when the family is larger, within a
ceiling the platform sets. `sales.seat_limit(party)` is read wherever seats are held or booked (passenger, agency,
counters, partners), and `sales.set_seat_limits` changes the three numbers (booking, family ceiling, agency group)
together, naming the decision behind them; it is the platform's alone (`policy.matrix`). The screens read the limit:
`GET /api/bookings/limits` (the passenger's own), `GET /api/ref` (`booking.max_seats`), the platform's page "Booking
rules" (`GET|PUT /api/admin/booking/seat-limits`).

## Data and API

- `sales.booking.journey_uid`, `journey_kind` (`ONE_WAY`, `ROUND_TRIP`, `MULTI_CITY`), `journey_leg` (1 to 6): the
  journey adds columns and no table, so it is seen exactly where its bookings are.
- `POST /api/journeys` and `POST /api/agency/journeys` (`{kind, legs[{trip_uid, from_seq, to_seq}], passengers[],
  pay_with, idempotency_key}`; the agency adds `contact_mobile`); `GET /api/journeys/{uid}`,
  `GET /api/agency/journeys/{uid}`, `GET /api/agency/journeys/options`. The same request sent again answers with the
  journey already booked.
- `GET /api/trips/search?stops=direct|stops`: direct trips only, or trips with stops only.
- Refusals: `JOURNEY_SHAPE`, `JOURNEY_ORDER`, `JOURNEY_INFANT`, `NOT_ENOUGH_SEATS`, `SALES_CLOSED`,
  `GROUP_THROUGH_AGENCY`, `GROUP_TOO_LARGE`, `TOO_MANY_SEATS`, and whatever a single booking of the journey would be
  refused for.
- The mobile app books journeys too: modes on the search screen, the trips chosen leg by leg with the direct / with stops
  filter, a journey checkout (travellers, documents on international trips, wallet or pay later), and the journey shown
  on each of its bookings.

## Not done (possible next steps)

- Connections found by the platform (a trip from A to C through B with two carriers, offered as one result).
- Paying a journey by card, instalments or financing in one payment (each booking is paid on its own for now).

## Seats chosen on each trip (1129 batch)

Each leg of a journey may name its seats (`JourneyLegIn.seats`, as many as the travellers who take a seat, all
different, `JOURNEY_SEATS` otherwise); without them the seats are given side by side as before. A seat taken by someone
else in the meantime refuses the whole journey with `SEAT_TAKEN` naming the leg and the seats, so nothing is booked
half. The web checkout shows each trip's seat map ("Choose seats") and keeps the choice per leg.
