# Prices of a route, carrier classes and the state's price bands

Owner's request N10, migration `1164_fare_matrix.sql`. It builds on the routes of the network in `NETWORK_ROUTES.md`
(1163).

## Who does what

| Who | Does |
|---|---|
| Carrier | prices every pair of stations of each of its routes |
| Platform | keeps the classes the state gives carriers, each carrier's class with its document, and the state's bands per class; turns the bands on when the state imposes them |

## The matrix of a route

* **`net.route_pair_fare`**: one price for each pair of stations of the carrier's route, from any boarding station to
  any later one. A direct route has one pair; a route of n stations has n(n-1)/2 pairs.
* The carrier saves the whole matrix at once (`PUT /api/carrier/routes/{uid}/fares`). A matrix with a pair missing, or
  a pair that is not on the route, is refused (`FARE_MATRIX_INCOMPLETE`).
* Before a matrix is saved, a pair is shown at the difference of the fare ladder (the fare from the origin of each
  station), as sales priced it until now.
* The fare ladder follows the first row of the matrix, so screens that show "from the origin" stay right.
* A pair that costs more than a longer pair containing it is allowed and reported back to the carrier, who may mean
  it.
* Prices are in the smallest unit of the currency, as everywhere in the API.

### Trips take the matrix

When a trip is made from the route, by hand or by a regular trip, the matrix is copied into `ops.trip_pair_fare`.
Search, booking and connections already read that table first and fall back to the ladder. A change of the matrix
applies to trips made after it; trips already made keep their prices.

### Distances

A carrier route on a route of the network takes each station's distance from its first station from the network
route (`net.route_stop.dist_from_origin_km`). The distance of a pair is the difference, which prices it per km.

## Carrier classes and the state's bands

* **`ref.carrier_class`**: the classes the state gives carriers (A, B, C or any other scheme), with their criteria.
* **`iam.carrier_class_assignment`**: the class of a carrier, on the state's document, from a date and up to a date
  if the document says so. A new class ends the current one, which stays as history; a carrier has one current class.
* **`pricing.state_price_band`**: the band of a class in money per km, a lowest and/or a highest, from a date, for
  every vehicle or for one vehicle type. Each band records the state's document.
* **`pricing.band_for(company, vehicle type, date)`** gives the band that holds: the vehicle type's own band first,
  else the class's general band; nothing while the setting is off or the carrier has no class.

### The switch

The setting `pricing.state_bands` is **off at launch**: carrier prices are free. With it on:

* saving a matrix refuses any pair whose price per km lies outside the class's general band (`FARE_OUTSIDE_BAND`, with
  the pairs);
* making a trip with a vehicle whose type has its own band refuses the trip if a pair of the route lies outside that
  band;
* the carrier's matrix screen shows the band and marks each pair below or above it.

Pairs without a known distance (a route not on the network) are not checked.

## Screens

* Carrier, Routes: a **Prices** button on each route opens the matrix (rows are boarding stations, columns later
  stations), with the distance of each pair and whether its price is still the ladder's.
* Platform, **Classes and price bands** (`/admin/pricing`, permission `pricing.tax_commission`): the switch, the
  classes, the bands and the carriers' classes with their history.

## Checks

* `backend/tests/test_fare_matrix.py`: full matrix required, ladder follows the first row, a trip takes the matrix;
  bands apply only while on, refused at save and at trip creation for a vehicle type's band.
* `db/tests/run_tests.sql` (1164): one current class per carrier, band order, no band while off, a type's band
  before the general one, pair order, the application deletes neither prices nor class history.
