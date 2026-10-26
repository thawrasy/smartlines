# Border crossings and airports

Owner's note N45, migration `1168_ports_of_entry.sql`. It builds on the United Nations geography of `1124` (areas and
places by P-code), the code changes of `1161` and the field-survey places.

## The register

* **`net.port_of_entry`**: one row per land crossing or airport.
  * **A fixed code**: `LND-<ISO country>-<nn>` for a land crossing (the country on the other side), `AIR-<IATA or short
    name>` for an airport. The code and the kind never change (`PORT_CODE_FIXED`); a port that ends is closed, and a new
    one gets a new code.
  * **Editable details**: the names in Arabic and English, the crossing on the other side and its country, the IATA code,
    the sub-district and place, the position, the operating status (active, restricted, closed) and whether an official
    source confirmed it, the border station that serves it, a review note.
  * **Position**: the linked United Nations location's, not the gate's own (`position_source = UN_LOCATION`). A surveyed
    position replaces it (`SURVEY`, match quality `SURVEYED`). A port without a known place (Al-Tanf, by the owner's
    decision tied to its sub-district) has no position until surveyed.
* **`net.port_of_entry_change`**: every change, field by field: the old and new value, who, when and why. A hand edit
  needs its reason (`PORT_CHANGE_REASON`); a file load is recorded as the file's. The history is never changed
  (`PORT_HISTORY_APPEND_ONLY`).

## Loading the owner's file

* The approved workbook has an `import` sheet with English headings in the United Nations' column names; the importer
  finds it by its headings (`backend/app/modules/geo/ports.py`).
* The whole file is checked first: code format and kind, the country in the code, names, IATA codes, P-codes nested
  governorate > district > sub-district, positions inside the country, match quality. Then it is checked against the
  loaded geography: every sub-district and place must exist. A mistake anywhere loads nothing.
* The same file twice changes nothing. A later file updates the ports the platform has not edited by hand; the edited
  ones are kept and listed (`kept_edited`).

## API and screens

* Public: `GET /api/geo/ports` (pickers, the public site): the ports that are not closed.
* Platform (`geo.manage`): `GET /api/admin/ports`, `POST /api/admin/ports/import`, `PUT /api/admin/ports/{code}`,
  `GET /api/admin/ports/{code}/history`; the **Border crossings and airports** page at `/admin/ports`.

## The approved file

28 ports: 19 land crossings (Lebanon 5, Jordan 2, Iraq 4, Turkey 8), 5 international airports and 4 local airports.
Match with the United Nations locations: 15 by name and place, 6 to the town itself, 6 to the nearest community (to be
reviewed), 1 to its sub-district. Operating statuses are left unconfirmed until an official source confirms them.

## Checks

* `backend/tests/test_ports_of_entry.py`: the file is checked whole and against the geography, loaded once, edits need a
  reason and are kept field by field, a surveyed position replaces the location's, the code never changes, a later file
  keeps the platform's edits.
* `db/tests/run_tests.sql` (1168): kind and code agree, reason required, history per field, code fixed, history
  append-only, position rules.
