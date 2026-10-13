# Trip numbers

The owner's decision of October 2026 (migration 1114). Passengers read a short trip number, as airline passengers read a
flight number; the long number stays the trip's reference for staff, reports and regulators.

| | Example | Who reads it | Unique |
| --- | --- | --- | --- |
| Trip number (`trip_code`) | `DC 101` | passengers: tickets, boarding passes, the station's screens, search, the apps | for a carrier on a day |
| Trip reference (`trip_no`) | `DCA-DAM-ALP-0730/15OCT26` | staff, reports, manifests, settlements, the regulator | always |

## How a trip gets its number

1. **The carrier's code for trip numbers** comes first: two characters, at least one a letter (`DC`, `Q7`), set by the
   platform when it defines the company (companies page, "Logo and code"; `PUT /api/admin/companies/{uid}/designator`).
   Without it the three-letter carrier code is used (`DCA 101`). It is unique on the platform and the reserved codes are
   refused (study 4.16 a).
2. **The service number** follows (1 to 9999, study 4.16 b):
   - the service number of the trip, or of the template that made it: the same departure keeps its number every day;
   - otherwise the number the same route had at the same local time on the nearest other day (within 60 days), when it
     is free that day;
   - otherwise the lowest free number of the extra block (5000 to 9999) that is not one of the carrier's service numbers.
   A carrier creating a trip by hand may name one of its service numbers (`service_number`); one it has not defined is
   refused (`SERVICE_NUMBER_UNKNOWN`).
3. **A carrier never runs two trips under one number on one day** (the trip's day where it starts, `service_date`):
   the database refuses the second (`trip_number_day_uq`; `TRIP_NUMBER_TAKEN` from the API). So a vehicle that runs
   several trips in a day runs them under different numbers, and the numbers repeat every day. A service number serves
   one template at a time on the same days (`SERVICE_NUMBER_TAKEN`).

The number is kept as printed (`ops.trip.trip_code`): a later change of the carrier's code names the trips made from then
on, never the tickets already sold. A cancelled trip frees its number for that day.

## Where it shows

The station's departure board, the counter's trips and the boarding pass, the passenger's search results, booking,
ticket and verification page, the driver's trips and offline pack, and the carrier's trip list (with the reference
under it). The passenger's message when a carrier cancels a trip names it too. Reports, manifests, settlements and the
partners' API keep the reference.

A regular trip's number is given by the platform when it approves the regular trip, in a block by trip type with an odd
number outbound and an even one on the return: see `REGULAR_TRIPS.md` (1117).
