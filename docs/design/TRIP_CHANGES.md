# Changes to a scheduled trip: another vehicle, a moved departure, passengers moved

Owner's request N42, October 2026. Built in migration 1148 (`db/schema/1148_trip_changes.sql`), the module
`backend/app/modules/trips/` (`changes.py`, `api.py`), the carrier's dialog `frontend/src/pages/carrier/TripChanges.tsx`
(Trips, "Changes" on each trip) and the platform's tab on the booking rules page ("Trip changes").

## What the owner asked

Change the vehicle of a scheduled trip when it breaks down and must be replaced, before or during the trip, with a reason
(breakdown, accident, other). Move the departure (postpone or change it) for reasons such as the late arrival of the
incoming trip, a breakdown, an accident under repair or a full replacement of the vehicle. Or cancel the trip entirely
and move its passengers to another trip. Passengers are told directly of the replacement trip number or the new time.

## The rule the three changes share

- **The trip keeps its number and its reference** (N43): the reference keeps the time it was first scheduled at; the new
  time is shown beside it and logged.
- **A reason from the platform's list**, in Arabic and English (`sys.setting` `trips.change_policy`; the schema holds the English wording, the Arabic comes from the Arabic messages file until the platform names it): breakdown, accident,
  late arrival of the incoming trip, repair in progress, vehicle replacement, weather, road closure, order of an
  authority, other. "Other" needs a note; the database refuses it without one. The platform edits the list (OTHER stays).
- **Logged** in `ops.trip_change`: kind, reason, note, who and when, what it did (`details`), how many bookings it touched,
  how many the system told and how many it could not reach.
- **Every booking still on the trip is told at once** (event `booking.trip_changed`, published to partners as v1): in
  the app and by e-mail for a passenger with an account, by text for a counter or agency sale that left a mobile, with
  the new time, vehicle plate, seat or trip. A booking no channel reaches (no account, no mobile) is listed for the
  carrier to call (`ops.trip_change_contact`); the carrier records each call (informed, no answer, wrong number).

## Another vehicle

`POST /api/carrier/trips/{uid}/vehicle` (permission `trip.reschedule` or `trip.publish`): a replacement vehicle, a new
driver if wanted, the reason; on the way (trip `DEPARTED`) the stop where it is changed, and only then.

- The vehicle must be in service with the carrier (its own or leased that day). The database checks it as for any trip:
  licences valid on the day, the vehicle free at that time (no overlapping trip), cargo within its limit.
- Seats keep their numbers where the new vehicle has them. A ticket whose seat the new vehicle lacks takes a free seat on
  the same stretch (`sales.ticket_move` keeps the old and new seat). If the smaller vehicle has too few free seats, the
  change is refused: move some passengers to another trip first.
- The seats the new vehicle lacks are closed (`BLOCKED`), not deleted; a larger vehicle later opens them again. The
  trip's seat map becomes the new vehicle's.
- `ops.vehicle_swap` keeps the swap with its reason, the stop on the way, the seats moved and whether the driver changed.

## A moved departure

`POST /api/carrier/trips/{uid}/reschedule` (permission `trip.reschedule`): the new departure (with its time zone) and the
reason. Every stop moves by the same minutes, and so do the crew's busy times; the database checks the vehicle is free at
the new time. A move larger than `max_shift_min` (1,440 by default) is refused: move the passengers instead.

A passenger whose trip moved by `free_cancel_shift_min` (60 by default) or more after the booking was made may cancel
with **everything back, the platform's fee included**, as when the carrier cancels; the booking page says so. Below the
threshold, the fare's own cancellation rules apply.

## Passengers moved to another trip, and cancelling

`GET /api/carrier/trips/{uid}/rebook-options` lists the carrier's coming trips that stop at every station of this trip
within `rebook_window_hours` (72), with the seats left, and the bookings on the trip.
`POST /api/carrier/trips/{uid}/rebook` (permission `trip.reschedule` or `trip.cancel`) moves named bookings, or all:

- Each booking **keeps its reference and its price**; the passenger pays no difference and nothing is refunded. Each
  ticket gets a **new number** (the old QR stops working) on the new trip, its seat number where free, else another free
  seat. The booking's money follows it: it is released when the new trip completes.
- A charter's seats are not moved this way; they follow the charter.
- To cancel the emptied trip, the carrier then uses "Cancel trip" (1102): whoever was not moved is refunded in full.

## The record

`GET /api/carrier/trips/{uid}/changes` returns the changes of the trip (and the moves onto it), each with the passengers
to call. The carrier's trip list marks a changed trip and its moved minutes. The passenger's booking page lists what
changed (new time, vehicle, trip) and whether they may cancel without fee.

## Not in this step

Moving passengers to another carrier's trip (by agreement) stays with the existing disruption decision (lease, interline,
rescue). The driver app reporting a breakdown uses the incident report (1101). Reports of changes per carrier (on-time
performance, breakdowns) and a cost centre per change come with the reporting wave.
