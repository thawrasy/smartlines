# Boarding stations and operating companies (requirements, recorded for later build)

Status: requirements recorded from the owner's answers (October 2026). Nothing here is built or switched on. Every item
becomes a platform setting, or a carrier-portal setting, that is off until it is enabled.

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

The platform setting that switches between them, and the rights each mode carries, are platform settings. Default off.

## 3. Permissions the operating company receives

Permissions are granted one by one, by the carrier (for a contracted operator) or by the platform (for a state-mandated
operator), and limited to the station's work:

- create a booking and change a booking;
- issue the boarding pass;
- run the boarding procedure at the station (check-in and the boarding record).

Nothing else is granted by default. Each permission is in the activity log with the counter and the staff member.

## 4. Check-in window

- The window is a setting: set in the platform settings, or in the carrier-portal settings.
- The window must also follow the rules of the competent authorities in the country, which may fix it. Until then it is a
  setting, and no new trip status is added for it yet.

## 5. Photo at the counter

- The counter has its own value in the photo settings, separate from the driver's value (for example `COUNTER_AT_STATION`),
  default off. The access is granted per party by the platform settings: the driver, the carrier, the booking office, the
  operating company, and the others as the platform lists them.
- Photos and biometric data are regulated by privacy law. The counter value cannot be switched on until a legal document
  supports it. The approval records the legal document number (migration 1095, optional there, required for this value
  later).

## 6. Agreement and licence references

- Each agreement between the carrier and the platform, and each licence the carrier needs, gets its own reference number.
  The platform applies a numbering scheme for each licence type.
- The references are stored in dedicated fields, one set for all the licences the carrier's operation needs.
- In the first phase the fields are optional. A platform setting makes them mandatory later, when the rules apply.
- The market has no binding rules yet; regulation will follow, and the setting follows the regulation.

## 7. Relation to what exists

- Carrier accounts are the `OPERATOR` portal. The state-mandated operating company gets a new portal role; the carrier-
  contracted one works through the carrier's portal.
- Trip statuses today: `PUBLISHED`, `BOARDING`, `DEPARTED`, `COMPLETED`, `CANCELLED`. The photo is shown only while the trip
  is `BOARDING` (migration 1096). The check-in window is a setting, not a status (section 4).
- The agency (agent) route for the photo (`GET /api/agency/tickets/{uid}/photo`) follows the same pattern: built, refused
  until the platform's `AGENT` value is on and the trip is boarding.

## 8. Still open (not decided by the owner)

1. The check-in window values, which the authorities may fix.
2. The format of the numbering scheme for the agreement and licence references.
3. The list of licences the carrier's operation needs, and which of them are in the first phase.
4. The legal document that supports the counter photo, and its number.
5. The exact permission list, after the first operating company is appointed.

## 9. Build order (when the owner decides)

1. Settings: the mode switch, the check-in window, the counter photo value, the reference fields (optional), each default off.
2. The two portal paths: the state-mandated role, and the carrier-granted permissions in the carrier portal, with tests of
   isolation (an operating company sees only the trips and tickets of carriers that gave it permissions).
3. Counter check, boarding pass and check-in records under the granted permissions, with the activity log.
4. Counter screens in the operating company's portal and the carrier portal.
5. Photo at the counter, under its setting and its legal document.
