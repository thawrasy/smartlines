# Trip numbers

The owner's decisions of October 2026 (migrations 1114 and 1119). Passengers read a short trip number, as airline
passengers read a flight number; the long number stays the trip's reference for staff, reports and regulators.

| | Example | Who reads it | Unique |
| --- | --- | --- | --- |
| Trip number (`trip_code`) | `DC 1201` | passengers: tickets, boarding passes, the station's screens, search, the apps | for a carrier on a day |
| Trip reference (`trip_no`) | `DCA-DAM-ALP-0730/15OCT26` | staff, reports, manifests, settlements, the regulator | always |

## How a trip gets its number

1. **The carrier's code for trip numbers** comes first: two characters, at least one a letter (`DC`, `Q7`), set by the
   platform when it defines the company (companies page, "Logo and code"; `PUT /api/admin/companies/{uid}/designator`).
   Without it the three-letter carrier code is used (`DCA 1201`). It is unique on the platform and the reserved codes are
   refused (study 4.16 a).
2. **The service number** follows, four digits (1000 to 9999, study 4.16 b; see below):
   - the service number of the trip, or of the template that made it: the same departure keeps its number every day;
   - otherwise the number the same route had at the same local time on the nearest other day (within 60 days), when it
     is free that day;
   - otherwise the lowest free number of the extra block (8000 to 8999) that is not one of the carrier's service numbers.
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

A regular trip's number is given by the platform when it approves the regular trip: see `REGULAR_TRIPS.md` (1117).

## Four digits, the direction and the legs of a vehicle's day (1119)

Every number has four digits. The first digit is the block of the trip type; the direction is on the last digit, as
airlines number a flight and its return (EK 1 Dubai to London, EK 2 back):

| Block | Numbers |
| --- | --- |
| Scheduled | 1000 to 4999 |
| International | 5000 to 5999 |
| Shuttle | 6000 to 6999 |
| Cargo | 7000 to 7999 |
| Extra (and trips made by hand without a number) | 8000 to 8999 |
| Kept for later (replacement and positioning runs) | 9000 to 9999 |

An outbound trip takes an odd number and its return the even number after it. The first three digits name the line of
a vehicle's day and the last digit its leg, 1 to 8: odd away from the carrier's home, even back.

| Vehicle's day | Numbers |
| --- | --- |
| Damascus to Aleppo at 07:00, back at 15:00 | DC 1201, DC 1202 |
| Four legs on a short line, Damascus - Homs | DC 1211, DC 1212, DC 1213, DC 1214 |

A number may continue the leg before it on the same vehicle (`net.service_number.follows_id`): the carrier's number one
lower, in the same block, ending in 1 to 7. The carrier decides: a regular trip continues one of its own (the request
names it and takes the number after it), or stands alone and starts a line of its own (the platform suggests the first
leg of a line whose eight numbers are free; a return on its own takes leg 2). The checks of the legs are in
`REGULAR_TRIPS.md`.

The numbers given before 1119 moved into their blocks with the same parity (scheduled +1000, international, shuttle and
cargo +4000, extra into 8000 to 8999). Trips ahead that nobody had booked took the new number; trips with bookings kept
the number printed on their tickets.

## The return on the same vehicle

A passenger on an outbound trip sees the trip that continues it on the same vehicle that day (`ops.trip_return`): in
search ("returns as DC 1202 at 15:00"), on the trip page, and on the booking with **Book the return**, on the web and in
the passenger app. The way back runs from where the traveller gets off to where they got on when the return stops at
both, else over the whole return trip. The vehicle is the one planned for both trips: one replaced on the day keeps
the numbers, and the page says so only while the planned vehicles match.
