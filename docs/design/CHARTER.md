# Charter: buses, minibuses and whole trips hired from carriers

Owner's request, October 2026. Migration `db/schema/1123_charter.sql`; API `backend/app/modules/sales/charter_api.py`;
screens `frontend/src/pages/charter/Charter.tsx` and `mobile/src/app/(passenger)/svc/charter.tsx`.

## What the owner asked

A tourism company books seats on scheduled trips (a group journey, `JOURNEYS.md`). Besides that it may hire from a
carrier a bus apart from the trips, or a whole scheduled trip with all its seats or some of them. Any carrier may offer
buses, minibuses, vans or whole trips for hire, to tourism companies or, by special request, to individual travellers,
under the policy the carrier applies.

## Offers: what a carrier hires out

A carrier (permission `charter.manage`) publishes offers (`sales.charter_offer`):

| Field | Meaning |
|---|---|
| kind | `VEHICLE` (a coach, a minibus, a van or a city bus apart from the trips) or `WHOLE_TRIP` (its scheduled trips, whole or in blocks of seats) |
| vehicle type, seats, vehicles | for a vehicle: the kind, its passenger seats and how many such vehicles it hires out |
| blocks | for trips: whether blocks are sold as well as whole trips, and the smallest block |
| audience | tourism companies, travellers (special request), or both |
| pricing | per day (per vehicle), per kilometre, per trip, per seat, or on request; the price |
| notice | the hours of notice the carrier needs |
| refunds | until how many hours before the start a customer may cancel, and the share refunded then (none later) |
| policy | the carrier's terms in its own words: what is included, fuel, waiting, the driver's hours, luggage, conduct |

Offers are public while active; the carrier pauses, resumes, edits or archives them.

## Requests, prices and payment

1. The customer (a tourism company's staff with `booking.on_behalf`, or a traveller) asks under an offer open to them
   (`OFFER_NOT_FOR_YOU` otherwise), giving a contact name and mobile:
   - a vehicle: from a city to a city, from a time to a time, how many travellers and vehicles, the itinerary
     (`NOTICE_TOO_SHORT`, `TOO_MANY_VEHICLES`, `TOO_MANY_PASSENGERS`);
   - a trip: one of the carrier's scheduled trips between two of its stops, whole (`WHOLE_TRIP_TAKEN` when seats are
     already sold) or a block (`BLOCK_TOO_SMALL`, `NOT_ENOUGH_SEATS`, `WHOLE_TRIP_ONLY`).
   The offer's terms at that moment are kept with the request (`terms`, a frozen snapshot): later changes to the offer
   do not change what was asked. The request shows what the offer's price comes to (an estimate), when it can say.
2. The carrier prices the request (valid for 1 to 168 hours, never past the start), may name the vehicle, or declines.
3. The customer accepts and pays at once: a traveller from the wallet, a tourism company from its prepaid balance.
   The money goes into the platform's escrow. For a trip, the seats are taken off sale at the same moment
   (`ops.seat_segment` status `BLOCKED`, recorded in `sales.charter_seat`); if they are no longer free, nothing is paid.
   A price past its time has lapsed (`QUOTE_EXPIRED`).
4. Once the service has begun the carrier marks it done: escrow pays the carrier, less the platform's commission
   (`charter.commission_bp`, none unless the platform sets one).
5. Cancellations: a carrier that cancels refunds in full; a customer that cancels a confirmed charter is refunded the
   offer's share if in time, nothing later, and the carrier keeps the rest (less the commission). Seats held go back
   on sale. An open request is withdrawn by the customer or declined by the carrier.

Every money movement is a ledger transaction naming the request (`CHARTER_PAY`, `CHARTER_RELEASE`, `CHARTER_REFUND`).

## Screens

- Carrier portal, "Charter and hire": the requests to price, confirmed and all; price, decline, name the vehicle, mark
  done, cancel; and the offers (new, edit, pause, archive).
- Tourism company portal, "Hire a bus or a trip", and the passenger website ("Hire a bus"): the offers open to them, the
  request form (for a trip, the carrier's trips of that day are listed to choose from), and their requests with
  accept and pay, withdraw and cancel.
- Passenger app: Services, "Hire a bus": the same for travellers.
- Platform, "Booking rules": every carrier's requests, the active offers and the commission.

## Not done (possible next steps)

- Naming the travellers of a chartered block so their tickets are issued and they appear on the trip's manifest
  (the seats are held; the carrier receives the passenger list as its policy says).
- Several vehicles of a vehicle hire named one by one, and a vehicle hire placed on the vehicle's schedule.
- Paying a charter by card, instalments or in parts (a deposit, then the rest).

## The travellers on a block of seats (1126)

Owner's decision on the next steps; migration `db/schema/1126_charter_passengers.sql`.

- Whoever hired seats of a scheduled trip (a block or the whole trip) names the travellers on them, on the web
  (Travellers, on a confirmed request) or in the app, until the trip leaves: a seat of the block they choose, or the
  next free one. A Syrian traveller gives the four parts of the name; a document number is stored encrypted, as for any
  booking.
- Each name is a ticket of the trip on a booking of the charter (`sales.booking.charter_request_id`), already paid by
  the charter (an amount of nothing, no invoice of its own): the travellers are on the carrier's list and the
  manifest the authorities receive, and board by ticket like anyone else. The carrier sees the list on the request.
- A name taken off cancels its ticket and puts the seat back in the block (still off sale). The booking is not
  cancelled or refunded on its own (`CHARTER_BOOKING`): the charter is, and its release cancels the tickets and frees
  every seat (`sales.charter_release_seats`).
- A trip the carrier cancels now cancels the charters holding its seats, each refunded in full.
- Babies on a lap are arranged with the carrier; each traveller named here has a seat.

