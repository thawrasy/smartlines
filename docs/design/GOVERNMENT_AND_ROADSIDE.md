# Government bodies and the vehicle movement code

Owner's notes N47 and N48 (25 October 2026). After the pilot the platform is meant to become a semi-governmental
platform that organises transport in Syria and sets its standard. The state's bodies reach it through their own door,
and every movement on the road can be checked without stopping the vehicle.

## N47: government bodies

* **The register** (`gov.authority`): each body with a fixed code, its kind and its names in Arabic and English:
  * `INTERIOR`: the Ministry of the Interior and internal security;
  * `PUBLIC_SECURITY`: public security;
  * `TRAFFIC`: traffic police;
  * `TRANSPORT_AUTHORITY`: the transport authority (regulator);
  * `FINANCE`: the Ministry of Finance (taxes and their remittance);
  * `TRANSPORT_MINISTRY` and `OTHER`.
* **How a body comes in**:
  * its members sign in at the inspector portal (`INSPECTOR`), each tied to one body;
  * and/or its systems call the integration API v1 with a client of kind `GOVERNMENT` tied to the body.
* **What each body may see** is set per body by the platform, starting from the kind's default (`gov.authority_scope`):
  * `MOVEMENTS`: trips, vehicles, crews, load;
  * `MANIFEST_NAMES`: passengers' names;
  * `ID_NUMBERS`: passengers' ID numbers, encrypted and shown only to the bodies that hold this scope;
  * `CARGO`: parcels and goods;
  * `TAX`: tax due and remitted;
  * `REGULATORY`: the regulator's indicators.
* **Records**: every look and every check is recorded with the member, the body, the time and the place, and the
  platform can review it. A body sees only what its scopes allow, whatever screen or API it uses.

## N48: the vehicle movement code

* **One large code per vehicle**:
  * a signed QR printed on a placard (A4, readable from a few metres) and fixed to the windscreen and the rear;
  * it names the vehicle, not a trip, so it is printed once;
  * at the moment of the scan it answers with the vehicle's current movement;
  * a lost or copied placard is revoked and a new serial printed (`fleet.vehicle_pass`).
* **The scan** (inspector portal, a phone's camera; later the security officer's app) shows, without stopping the
  vehicle:
  * the carrier and its licence state;
  * the vehicle, its plate and its seats;
  * the movement now: a scheduled trip with its number, route, departure and stops, or a charter, shuttle, parcel run
    or freight movement;
  * the crew;
  * the count of passengers boarded against the seats sold and the seats of the vehicle;
  * parcels and goods.
* **Warnings** on the scan:
  * more people boarded than seats;
  * a vehicle blocked or with an expired document;
  * a driver whose licence has expired;
  * a vehicle on the road with no published movement;
  * a manifest not issued.
* **Sample check**: the officer asks for a sample; the server picks the passengers at random (the officer cannot choose),
  shows their seats and names (within the body's scopes), and the officer records each one as checked or as an issue.
  A full check lists everyone.
* **The inspection record** (`sec.roadside_check`): the vehicle, the movement, the body, the officer, the place, the time,
  the result and the sample, never changed afterwards. The carrier sees the checks of its own vehicles.
* **Every module**: the scan resolves the vehicle's movement in every service the platform runs. Each module that
  moves people or goods on a vehicle answers the same question ("what is this vehicle doing now"), so a new module
  joins the scan the way it joins the menu.

## Build order

1. Database: bodies, scopes, members, vehicle passes, roadside checks (one migration), checks in `db/tests`.
2. API: register and scopes (platform), scan, sample and record (inspector), placard PDF (carrier), API v1 for bodies.
3. Screens: platform "Government bodies"; inspector "Roadside check" with the camera; carrier "Vehicle placard".
4. Tests, generated docs, Arabic report.
