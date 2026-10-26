# Trip numbers from the carrier's range

Owner's request N7 and decisions of 23 October 2026, migration `1165_number_ranges.sql`. It builds on the four-digit
blocks and the legs of a vehicle's day of `1119_trip_rotations.sql`.

## Ranges

* Numbers may repeat across carriers: the carrier's designator tells them apart (`DC 1201`, `QD 1201`). So every
  carrier has by default the whole block of each trip type: scheduled 1000-4999, international 5000-5999, shuttle
  6000-6999, cargo 7000-7999, extra 8000-8999.
* **`net.number_range`**: the platform may narrow a carrier's range in a block (from - to, inside the block) and widen
  it again, up to the whole block. A new range ends the one before, which stays as history. Numbers already in use
  outside a narrowed range stay with their regular trips.
* **`net.number_range_request`**: a carrier whose range fills asks the platform for more, one open request per block.
  Setting the range answers it; the platform may also decline it with a reason.
* `ops.carrier_number_range(company, block)` gives the range in force; `ops.carrier_number_problem` refuses a number
  outside the block, of the wrong parity (odd outbound, even return) or outside the range.

## The number is required

* **Regular trips.** The carrier picks the number from the free numbers of its range that fit the type and direction
  (`GET /api/carrier/numbers`); the form fills in the default. A request without a number takes the default, so every
  request carries a number of the carrier's range. The default is the first leg of a line whose eight numbers are free
  (so the vehicle's next legs can follow it), else the lowest free number. A leg that continues another still takes
  the number after it. The platform keeps the right to give another number at approval.
* **Trips made by hand.** The form requires a number (`GET /api/carrier/numbers/for-trip`): one of the carrier's numbers
  on the route that day, or a free extra number of its range, the default filled in. A free extra number runs the trip
  on its own without becoming a service number.
* When no number is free the carrier is told (`NUMBER_RANGE_FULL`) and asks for a wider range.

## Screens

* Carrier, Regular trips: the number is a list of the free numbers with the default marked; the carrier's ranges and
  the request for a wider range sit under the list of regular trips.
* Carrier, new trip: the number is a list of the route's numbers that day and the default extra number.
* Platform, **Trip number ranges** (`/admin/numbers`, permission `schedule.approve`): the blocks, the carriers' requests
  (set the range or decline) and the ranges set with their history.

## Checks

* `backend/tests/test_number_ranges.py`: the whole block by default, narrowing and its effect on the free numbers and the
  default, refused numbers, a request with the default number, one open request per block, widening answers it,
  declining, a hand-made trip under a free extra number.
* `db/tests/run_tests.sql` (1165): the whole block by default, a range inside its block, numbers outside it refused, the
  free numbers in the range with the parity, the whole block back with history kept, only the platform sets a range.
