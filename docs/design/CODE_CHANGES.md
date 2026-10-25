# Codes that can be changed

Owner's request N39, migration `1161_code_changes.sql`. It builds on the administrative geography of `ADMIN_GEOGRAPHY.md`
(1124) and the cities of `CITY_CLASSES_AND_PICKERS.md` (1160).

## Ids stay, codes change

Every governorate, district, sub-district, place, city and station keeps its internal id. Stations, routes, trips,
bookings and addresses link by id, so a new code breaks no link. Nobody writes a code directly: a trigger on each of the
four tables refuses it unless an approved change is being applied.

## A change, step by step

1. **Preview** (`ref.code_plan`, `POST /api/admin/geo/codes/preview`): every code the change touches, with its new value.
2. **Ask** (`ref.request_code_change`): a reason, an optional source document (a decision, a letter) and the date it takes
   effect (today or later). It is refused when a new code is taken.
3. **Decide** (`ref.decide_code_change`): another person approves or rejects. A rejection says why. The person who asked
   never decides; they can withdraw the change until it takes effect.
4. **Take effect**: at once when approved on or after its date. Otherwise the worker applies it once its date has come
   (`ref.apply_due_code_changes`). The plan is worked out again at that moment, so what was added in the meantime moves
   too. If a code was taken in the meantime, the change is marked `FAILED` with the reason.

## What a change carries down

| Changed | Carried to | Example |
|---|---|---|
| Governorate | its districts and sub-districts | SY14 → SY20: SY1401 → SY2001, SY140100 → SY200100 |
| District | its sub-districts | SY1401 → SY1405: SY140100 → SY140500 |
| City | its stations | DAM → DMS: SY-DAM-C001 → SY-DMS-C001 |
| Place, station | itself only | C1400 → C1499 |

* A district or sub-district keeps the code of the area it lies in as its prefix; to move the prefix, change that area.
* Communities and neighbourhoods (C…, N…) are not prefixed by their area in the United Nations scheme, so they are
  changed one by one. Their link to their area moves with the id.
* A station's code carries its own city (`SY-RDM-X901` for a station in Rif Dimashq).
* Corrections of published names (1127) scoped to an area or place follow its new code.

## When a code cannot be used

| Reason | Meaning |
|---|---|
| `IN_USE` | another thing has that code now |
| `OLD_CODE_OF_ANOTHER` | another thing had that code before; old codes are never given to something else |
| `ANOTHER_CHANGE_WAITING` | a change of the same thing is already waiting |

## Old codes

`net.code_history` keeps every old code, with the time from which it was used and the time it ended.

* `ref.code_entity(kind, code)` finds a thing by a current or an old code.
* `ref.current_code(kind, code)` gives the code in use now.
* `ref.code_on(kind, id, time)` gives the code a thing had at a time, for reports by date.
* The trip search, connections, parcels, charter, freight and family addresses accept an old city code.
* A later United Nations workbook or boundaries file that still carries old codes updates the re-coded areas and places.
  An area the file adds under a re-coded one takes the new prefix (SY1405 under SY14, re-coded SY20, becomes SY2005).
* Recorded data is not rewritten. Tickets, trip references, manifests, invoices and logs keep the code they were issued
  with; live screens show the current code.

The requests and old codes live in `net`, which already depends on `ref`, because they point at stations as well as
areas, places and cities. The functions are in `ref` with the rest of the geography.

## API (geo.manage)

* `POST /api/admin/geo/codes/preview` `{kind, code, new_code}`
* `GET /api/admin/geo/codes/changes?status=`
* `POST /api/admin/geo/codes/changes` `{kind, code, new_code, reason, source_document, effective_on}`
* `POST /api/admin/geo/codes/changes/{uid}/decide` `{approve, note}`
* `POST /api/admin/geo/codes/changes/{uid}/cancel`
* `GET /api/admin/geo/codes/history?kind=&code=`

## Screen

On the platform's Geography page, the Codes card has:

* the list of changes with their state, who asked and who decided;
* the form to change a code, with its preview;
* the decision for another person;
* a look-up of the codes a thing has had.

## First use

The demo border crossing of Jdeidet Yabous lies in Rif Dimashq, so its station code moves from `SY-DAM-X901` to
`SY-RDM-X901`. New demo databases are seeded with the new code. An existing one is changed through this screen, and the
old code keeps finding the station.

Tests: `backend/tests/test_code_changes.py`; database checks under "Code changes (1161)".
