# The roads guide

Owner's request N38, migration `1162_roads.sql`. It builds on the administrative geography of `ADMIN_GEOGRAPHY.md`
(1124) and prepares the platform's routes (wave 5b), which are defined along these roads.

## What it holds

| Table | Holds |
|---|---|
| `net.road` | a numbered road: number (M5, P01, S101), class, names in Arabic and English, regional number (M45), length, verification |
| `net.road_point` | the places along a road in order: the place (United Nations P-code), position, km from the point before and from the start, border crossing |
| `net.road_junction` (view) | the places on two roads or more, worked out from the points |
| `net.road_verification` | each verification step, on a document, asked by one person of the platform and decided by another |
| `net.road_correction` | corrections proposed by carriers or the platform, reviewed by another person |

The class follows the road number: M is an international main road, P and D domestic main roads, S domestic secondary
roads.

## Loading the owner's workbook

`POST /api/admin/roads/import` (geo.manage) reads two sheets, found by their columns rather than their names: the road
points and the index of roads. The geography must be loaded first.

**Refused (nothing loads):**

* a road number in the points that is not in the index;
* an order that does not run from 1 without gaps;
* a point count different from the index;
* a place that is not an active place of the loaded geography;
* a place whose sub-district differs from the file's;
* a governorate, district or sub-district that does not nest.

Old codes are read through the code changes (1161).

**Reported, loaded anyway (warnings to check):**

* a distance shorter than the straight line between two points;
* a running total that does not add up;
* a length different from the index;
* a position more than 1 km from the place's.

Loading the same file again changes nothing. A newer file updates the roads still at `OWNER_FILE` and keeps the roads
verified beyond it.

The owner's file (`Syrian_Roads_Guide_UN_Pcodes_1.xlsx`) loads 43 roads (8 international, 21 domestic main, 14
secondary), 174 points and 41 junctions. It comes with 8 warnings, the same ones found when the file was checked:

* five legs shorter than the straight line (M2, M4, P02, P11, P12 and S110);
* two running totals (M1, M20).

## Verification

Every road starts as `OWNER_FILE`.

* One person of the platform asks to raise it to `CARRIER_CONFIRMED` or `AUTHORITY_APPROVED`, naming a document.
* Another person approves or rejects it; a rejection says why.
* One step waits at a time, and every step is kept.

## Corrections

* A carrier (`/api/carrier/roads/{code}/corrections`) or the platform proposes a correction of a point's place, of a
  distance, or a remark.
* Another person of the platform accepts or rejects it; the proposer never decides.
* An accepted place moves the point to that place and its position. An accepted distance is written and the running
  totals and the road's length are worked out again.

## Screens

* **Platform, Roads guide:**
  * the load with its report and warnings;
  * the network drawn from the points (plain SVG, no outside map tiles), coloured by class, with the junctions;
  * the list of roads by class;
  * a road's points with the roads crossing at each;
  * the correction and verification queues.
* **Carrier, Roads guide:** the same network and list, a road's points, the correction form, and the carrier's own
  proposals.

Tests: `backend/tests/test_roads_guide.py`; database checks under "Roads guide (1162)".
