# Government bodies and the vehicle movement code

Owner's notes N47 and N48 (25 October 2026). After the pilot the platform is meant to become a semi-governmental
platform that organises transport in Syria and sets its standard. The state's bodies reach it through their own door,
and every movement on the road can be checked without stopping the vehicle.

## N47: government bodies

* **The register** (`sec.authority_profile`): each body with a fixed code, its kind and its names in Arabic and English:
  * `INTERIOR`: the Ministry of the Interior and internal security;
  * `PUBLIC_SECURITY`: public security;
  * `TRAFFIC`: traffic police;
  * `TRANSPORT_AUTHORITY`: the transport authority (regulator);
  * `FINANCE`: the Ministry of Finance (taxes and their remittance);
  * `TRANSPORT_MINISTRY` and `OTHER`.
* **How a body comes in**:
  * its members sign in at the inspector portal (`INSPECTOR`) from the platform's officer app on their phones (or the
    web), as platform accounts made members of one or more bodies (`sec.authority_member`); a member of several bodies
    names the body each check is made for;
  * and/or its systems call the integration API v1 with a client of kind `GOVERNMENT` tied to the body, when the body
    asks to link its own applications.
* **What each body may see** is set per body by the platform, starting from the kind's default (`sec.authority_scope`),
  and each scope is in force only once a second person approved it, for its dates (`sec.authority_may`):
  * `MANIFEST_VEHICLE` and `TRACKING`: the movement, the vehicle, the crew, the counts;
  * `MANIFEST_PERSON`: passengers' names and seats (the sample);
  * `IDENTITY`: passengers' ID numbers, encrypted and shown only to the bodies that hold this scope;
  * `MANIFEST_CARGO`: parcels and goods;
  * `TAX`: tax due and remitted;
  * `REGULATORY`: the regulator's indicators.
* **Records**: every look and every check is recorded with the member, the body, the time and the place, and the
  platform can review it. A body sees only what its scopes allow, whatever screen or API it uses.

## N48: the vehicle movement code

* **One large code per vehicle**:
  * a QR printed on a placard and fixed to the windscreen and the rear; the code is short (`MS1` and 13 letters or
    digits, 65 bits of a keyed hash of the vehicle and the serial), so it fits the smallest symbol (21 x 21 modules)
    and the symbol fills the page: about 12 mm a module on A3 (the default) and 9 mm on A4. Tested: it still decodes
    when the symbol is 66 pixels wide in the photo and slightly blurred, which a phone reaches from many metres and from
    a moving vehicle;
  * the code cannot be guessed; the server keeps only its digest and finds the placard by it, and answers only while
    the placard is in force. A placard printed before a change of the QR key still matches and is reprinted with the
    key it was made with;
  * it names the vehicle, not a trip, so it is printed once;
  * at the moment of the scan it answers with the vehicle's current movement;
  * a lost or copied placard is revoked and a new serial printed (`fleet.vehicle_qr_tag`).
* **The scan** (the platform's officer app on the security officer's phone: the camera reads the code; the code can
  also be typed) shows, without stopping the vehicle:
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
* **The inspection record** (`fleet.field_check_log`): the vehicle, the movement, the body, the officer, the place, the time,
  the result and the sample, never changed afterwards. The carrier sees the checks of its own vehicles.
* **Every module**: the scan resolves the vehicle's movement in every service the platform runs. Each module that
  moves people or goods on a vehicle answers the same question ("what is this vehicle doing now"), so a new module
  joins the scan the way it joins the menu.

## What the schema already holds

The study planned this, and the tables existed without screens or API. N47 and N48 build on them, not beside them
(migration 1169):

* `sec.authority_profile`: the bodies (kinds, protocol, data scope), already referenced by border manifests, alerts
  and data requests. It gains the new kinds, names in both languages, members and scopes.
* `fleet.vehicle_qr_tag`: the signed sticker on the vehicle for field verification (study 4.18 e). It gains a serial
  and the placard.
* `fleet.field_check_log`: every field query by security officers and authorised bodies. It gains the movement, the
  warnings, the sample and the result of each person checked; the body of each check is kept in
  `sec.field_check_body`, so the fleet schema does not depend on the security schema.

## Build order

1. Database: bodies, scopes, members, vehicle passes, roadside checks (one migration), checks in `db/tests`.
2. API (`app/modules/roadside`): register and scopes (platform), scan, sample and record (inspector), placard PDF
   (carrier); members through the routes of the regular trips module; API v1 for bodies.
3. Screens: platform "Government bodies"; inspector "Roadside check" with the camera; carrier "Vehicle placard"; the
   officer mode of the mobile app.
4. Tests, generated docs, Arabic report.
