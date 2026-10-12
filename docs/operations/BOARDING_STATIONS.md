# Boarding stations and boarding operators (requirements, recorded for later build)

Status: requirement recorded, not built. Nothing here is switched on. Every item below becomes a platform setting or a
carrier-portal setting that is off until it is enabled. Owner's direction, October 2026.

## 1. What it is

Passengers are processed at a boarding station, as at an airport: a counter check, then boarding onto the bus. A
boarding station can be run by an operating company, which acts in the name of the carrier. Each operating company has
its own counter or counters at the station. The carrier is the party that sells and transports; the operating company
performs the passenger processing for it.

Typical sequence, per passenger and ticket:

1. Arrival at the station; the passenger goes to the counter of the operating company that serves their trip.
2. Counter check: the ticket, the identity document, and the boarding photo when the platform shows it to the counter.
3. The counter issues the boarding status (checked in) for the ticket and the seat.
4. Boarding onto the bus: the driver or the station staff confirms the boarding scan (the existing boarding path).

## 2. Switches (platform settings, default off)

- `station.operators_enabled`: whether the platform runs boarding stations at all. Off at launch.
- `station.counter_roles`: the operating company's counter staff may check passengers in and see the photo, only when the
  platform allows it (a value added to `photo.view_access`, for example `COUNTER_AT_STATION`, default false). Same approval
  stages as the other photo settings.
- Each station and counter is a platform record; changing a station or a counter passes the platform's approval stages.

## 3. Carrier-portal switches (per carrier, default off)

- `delegate_boarding_to_operator`: the carrier allows an operating company to process its passengers at a station.
  Off unless the carrier and the platform have an agreement, and the agreement is recorded with the switch.
- `operator_company_id`: the one operating company the carrier delegates to (one per carrier at first).
- Each delegation is opened by the platform after the agreement is signed; the platform records the agreement reference.

## 4. Access rules

- An operating company sees only the trips of carriers that delegated to it, and only the tickets of those trips.
- Its counter staff act under the delegation, and every action is in the activity log with the counter and the staff.
- The photo at a counter is shown only when the platform setting for counter staff is on and the trip is in its check-in
  or boarding window (see open questions).
- A passenger's photo is never kept by the operating company; the platform holds it (1086).

## 5. Relation to what exists

- Carrier accounts are the `OPERATOR` portal; an operating company would need its own portal role or a company type
  inside the same portal. Open question below.
- Trip statuses today: `PUBLISHED`, `BOARDING`, `DEPARTED`, `COMPLETED`, `CANCELLED`. The photo is shown only while the
  trip is `BOARDING` (migration 1096). A check-in window would be a new status or a time window.
- The agency (agent) route for the photo (`GET /api/agency/tickets/{uid}/photo`) is the same pattern: it is built, and it is
  refused until the platform's `AGENT` value is on and the trip is boarding.

## 6. Open questions (for the owner, before the build)

1. Does the check-in window need its own trip status, or is a time window before departure enough?
2. Does the operating company get its own portal role, or a company type inside the carrier (`OPERATOR`) portal?
3. Is the counter photo view a separate platform value, or the same value as the boarding driver?
4. Which legal basis applies to showing the photo at a counter run by a company other than the carrier?
5. How is the agreement between the carrier and the platform recorded: a document number on the delegation change, as with
   the photo switch (1094/1095)?

## 7. Build order (when the owner decides)

1. Settings and the delegation records, with approvals (no counter screens).
2. Counter check status and the operating company's scoped reads, with tests of isolation.
3. Counter screens in the carrier portal and the operating company's portal.
4. Photo at the counter, under the settings, with the audit trail.
