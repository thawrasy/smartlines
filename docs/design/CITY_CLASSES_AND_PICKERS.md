# Cities by class and pickers from the governorate down

Owner's request N37, migration `1160_city_classes.sql`. It builds on the administrative geography of
`ADMIN_GEOGRAPHY.md` (1124, 1125).

## Classes

A city of the network is a **main city** or a **secondary destination** (`ref.city.city_class`).

* The cities in the network when 1160 came in were made main cities, once.
* A place the platform opens for routes later is a secondary destination until the platform makes it a main city.
* The platform sets the class on the Geography page (Cities of the network), `PUT /api/admin/geo/cities/{code}`
  (`geo.manage`).
* Wherever cities are listed, the main cities of each governorate come first.

## One level at a time

A city's governorate comes from its place in the United Nations geography: the first four characters of its
sub-district's code (`ref.city_governorate`). A city with no place yet is listed without a governorate.

`GET /api/geo/cascade?governorate=&city=&area=` (`ref.geo_cascade`) gives every level for what is already chosen:

| Level | What is listed |
|---|---|
| governorates | the governorates that hold cities of the network |
| cities | the cities of the chosen governorate (all when none is chosen), main cities first |
| areas | the neighbourhoods of the chosen city, by the city's areas |
| stations | the active stations of the chosen city, or of the chosen neighbourhood |

The web component `GeoCascade` draws these levels as linked lists, down to the city, the area or the station.

## Where it is used

* Station creation on the platform: governorate, city and neighbourhood, or a place found by name.
* The search form, charter requests and every list of cities: grouped by governorate, main cities first.
* `GeoCascade` is ready for the parcel drop-off points and addresses of later waves.

## The United Nations file in full

The complete workbook kept for the trial loads with the existing importer (`POST /api/admin/geo/import`). A full load
on the demo database (25 October 2026) took 3.5 seconds and held:

| Level | Count |
|---|---|
| Governorates | 14 |
| Districts | 62 |
| Sub-districts | 272 |
| Communities | 7,593 |
| Neighbourhoods | 414 |

It added 8,340 rows, updated 15 and retired 1, and linked 10 cities of the network to their communities. After it, the
pickers list 12 governorates holding cities of the network, and 19 of the 21 domestic cities have a governorate. The two
left without one, Rif Dimashq (RDM) and Quneitra (QNT), are named after their governorates rather than a community: the
platform links each to its community (Serve on the Geography page) for it to take its place in the pickers.

Tests: `backend/tests/test_geo_cascade.py`; database checks under "City classes (1160)".
