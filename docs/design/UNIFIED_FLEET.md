# One fleet for every vehicle (1172, 1173, 1174)

Owner's notes of 25 October 2026: the list of vehicle types must cover the makes, models and trims since 2020 and stay
editable; every vehicle (whatever its kind) is defined from one screen; trucks have a tractor head and a trailer, each
with its own plate and licence where the country numbers them apart; every vehicle is insured with a company from the
insurers registry; service dates are kept (oil change, periodic service, maintenance contract); a vehicle in the
workshop takes no trip and no rental; a car is hired with or without a driver, with kilometres a day or unlimited.

## The list of makes, models and trims (1172)

| Part | What it holds |
|---|---|
| `ref.vehicle_make` | Make with its Arabic name and country, reviewed by a second person (1157) |
| `ref.vehicle_model` | Model with its Arabic name, class, type, body, seats or weight, first and last year, production, confidence |
| `ref.vehicle_trim` | Trim of a model with its Arabic name, fuel (petrol, diesel, hybrid, plug-in, electric, range extender, gas) and years |
| `ref.vehicle_*_change` | Every edit, field by field, with who, when and why; a name changes only with a reason |

* The owner's workbook (sheets `vehicle_models_import` and `trims`) comes in through `POST /api/admin/vehicle-models/import`:
  makes and models wait for a second person's review; trims go under the model of the same make and name.
* `PATCH /api/admin/vehicle-models/{makes|models|trims}/{uid}` corrects an entry; `GET` the same path returns it with its history.
* `DELETE` removes an entry only while nothing uses it. A model chosen by a vehicle or by a carrier's request, and a make
  with models or requests, are refused (`MODEL_IN_USE`, `MAKE_HAS_MODELS`, `MAKE_IN_USE`) and are retired instead. The
  database refuses it too (`ref.tg_catalog_delete`); a deleted entry takes its trims and edit history with it, and the
  delete stays in the activity log.

## Lines of business by contract (1173)

`iam.company_fleet_line` holds the lines the platform opened for a company under its contract: buses, trucks, car
rental, taxis, each with a contract reference and its dates. A carrier starts with buses (as before) and a rental
company the platform registers holds car rental; the platform opens trucks and taxis from the company file
(`/api/admin/companies/{uid}/fleet-lines`). A vehicle of a use needs its line (`FLEET_LINE_CLOSED`, checked by the
database). Trucks and rental cars also need the platform's cargo and car rental modules switched on.

## The vehicle

`fleet.vehicle.fleet_use` names the use: coach, city bus, minibus, van, rigid truck, tractor head, rental car, taxi.
The class follows (bus, truck, car). The vehicle keeps its odometer, colour, fuel and trim; its edits are kept (1170).

| Use | Asked when it is defined |
|---|---|
| Bus kinds | Seat layout (the seats come from it) |
| Truck, tractor head | Payload, gross and empty weight, axles |
| Rental car | Rental class and home branch |
| Taxi | Taxi licence number and expiry |
| All | Plate and its country, chassis and engine numbers, model and trim from the list, year, colour, fuel, odometer, insurance |

### Head and trailer

`fleet.trailer` has its own plate (unique per country), chassis, type, payload and axles, licences
(`fleet.license_record`, subject `TRAILER`) and insurance. `fleet.truck_combination` couples a head to a trailer for a
period; neither is coupled twice at once. A trailer's plate changes only with a reason, kept in `fleet.trailer_change`.

### Insurance

`fleet.insurance_policy` names the insurer from the registry (`ref.insurer`), the policy number, the cover and the
dates, for a vehicle or a trailer (one of the two). The policy also enters `fleet.license_record` as the insurance
licence that governs eligibility. `source` and `verified_at` are ready for the check against the insurer's system, to
be connected later.

### Service plans and the workshop

`fleet.service_plan` holds oil changes, periodic services, tyres, inspections by distance and months, or a maintenance
contract with its provider and number. `fleet.service_due` gives the next service and whether it is due.
Sending a vehicle to the workshop (`fleet.maintenance_visit`) opens an out-of-service period of kind `MAINTENANCE` and
marks the vehicle `IN_MAINTENANCE`: no trip is opened on it (1101) and it is not hired (`VEHICLE_IN_MAINTENANCE`) until
it comes back. The return closes the period, makes the vehicle active and moves its plan on (last kilometres and date).
A vehicle with a renter or on a trip is not sent.

### Colours and axles from lists (1174)

Owner's notes of 25 October 2026: colours and axles are defined in advance so that entry mistakes and misspelt
duplicates cannot happen.

| List | What it holds |
|---|---|
| `ref.vehicle_colour` | 25 colours to start (white, pearl white, black, silver, grey, dark grey, beige, champagne, brown, bronze, gold, yellow, orange, red, maroon, pink, purple, blue, navy, sky blue, turquoise, green, dark green, olive, two-tone) with English and Arabic names and a swatch; each name is unique |
| `ref.axle_config` | Wheel formulas of trucks and tractor heads (4x2, 4x4, 6x2, 6x4, 6x6, 8x2, 8x4, 8x6, 8x8, 10x4, 10x6, 10x8: wheel positions by driven positions, as makers and regulators write them) and trailer axle groups T1 to T8; each with its number of axles |

* `fleet.vehicle.colour_code` and `fleet.trailer.colour_code` point at the colour list; the free colour text of 1173 is
  gone. `fleet.truck_unit.axle_config` and `fleet.trailer.axle_config` point at the axle list; a trailer's number of
  axles follows its group. A truck takes a wheel formula, a trailer an axle group (`AXLE_KIND`).
* The platform adds an entry, renames it with a reason, or retires it (Registries, tab "Colours and axles";
  `/api/admin/reference-lists`). A code never changes and nothing is deleted; a retired entry stays on the vehicles
  that have it and is not chosen again (`COLOUR_RETIRED`, `AXLE_RETIRED`). Every edit is kept.
* Axle values typed before the list are kept as retired entries marked `LEGACY`, so no truck loses its value.
* Screens pick colours from swatches and axles from a list (`/api/fleet/lists`); the API refuses anything else
  (`COLOUR_UNKNOWN`, `AXLE_UNKNOWN`). Coupling a head whose axles and weights were never recorded is refused
  (`TRUCK_DETAILS_MISSING`).

## Car rental

`rent.rental_rate` gives unlimited kilometres, or kilometres a day with the price of each extra one, and the price of a
driver a day. A renter books with or without a driver. The rental desk (`/api/fleet/rentals`) gives the booking a car,
and a driver when hired with one; at pickup and return it records the odometer and fuel. `rent.hire_distance` gives the
kilometres driven, allowed and over, and their charge, added to the contract's final amount. The odometer never goes
back, and each reading moves the car's own odometer.

## Screens

* Fleet (carrier portal): the lines the contract covers, the vehicles by use, the trailers, and each vehicle's file
  (details and licences, insurance, service plan, workshop, trailer). The rental desk is a tab when car rental is open.
* Companies (platform): the company's lines of business, opened and closed by contract.
* Vehicle makes and models (platform): Arabic names, years and trims; edit with history; delete while unused.
* Colours and axles (platform): the two lists, with swatches, what uses each entry, edit with history and retire.
