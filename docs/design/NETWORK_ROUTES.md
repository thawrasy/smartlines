# Routes of the network

Owner's requests N11, N37 and N38, migration `1163_network_routes.sql`. It builds on the roads guide of
`ROADS_GUIDE.md` (1162).

## Who does what

| Who | Does |
|---|---|
| Platform | defines the routes of the network and changes them, in versions approved by a second person |
| Carrier | picks a route, the stations it boards and alights at and the stops it serves; sets its times, fares and trip numbers; asks for a route the network lacks |

Owner's decisions (23 Oct 2026):

* Routes are defined and edited by the platform only, now as well: general routes with their stations, until the
  regulator's lines are in force.
* The carrier does not create or edit routes; it defines its trips from one station to another on them.

## A route and its versions

* **`net.network_route`**: the route from one station to another, with names in Arabic and English. The code is set by
  the system: origin city - destination city - number (`DAM-ALP-01`).
* **`net.network_route_version`**: one version of the route. It carries:
  * its stations (`net.network_route_stop`): in order, each with its distance from the start and whether it is
    mandatory;
  * the road segments it follows (`net.network_route_segment`): a road of the guide, from one of its points to another.

**With segments:**

* each segment starts where the one before ends;
* the distance is the sum of the segments;
* a station standing at a road point, or in that point's community, takes its distance from the start from the roads;
* the governorates crossed are listed from the road points passed.

**Without segments**, the platform gives the distance and each station's distance from the start.

**Versioning:**

* One person proposes a version; another approves or rejects it (a rejection says why).
* An approved version takes effect on its date: at once when due, else from the worker
  (`net.activate_due_route_versions`).
* The version in effect is retired when a newer one takes effect.
* One version waits at a time; who proposed it can withdraw it.
* A version is written whole when it is proposed and never changed after. A trigger refuses any later change to its
  stations or segments.
* A new version keeps the route's origin and destination; another pair of stations is another route.

## The carrier's service on a route

`POST /api/carrier/routes` takes the network route, the stations served in its order, the times and the fare ladder.

* **Checks:** every station must be on the route's version in effect and in its order, and every mandatory station
  between the first and the last must be served.
* **Code:** set by the system, as designator - from city - to city - number (`QD-DAM-ALP-1`).
* **What the route records:** the network route and version, and the distance between the two stations.
* **Trips:** trips made from it keep that version.

The setting `network.platform_routes_only` is on. Switching it off lets carriers draw free routes as before; their code
can still be left to the system.

## Requests for a route

A carrier asks for a route between two stations, saying through where and why (`net.route_request`). The platform
answers: done (naming the route opened) or declined, with a reason. The carrier sees the answer on its routes page.

## API

* `GET /api/network/routes`, `GET /api/network/routes/{uid}` (signed in)
* `POST /api/admin/network/routes`, `POST /api/admin/network/routes/{uid}/versions`
* `GET /api/admin/network/versions`, `POST /api/admin/network/versions/{uid}/decide`, `POST .../withdraw`
* `GET /api/admin/network/requests`, `POST /api/admin/network/requests/{uid}/answer`
* `GET|POST /api/carrier/route-requests`

## Screens

* **Platform, Network routes:**
  * the routes in effect;
  * a route's versions, stations, roads and governorates;
  * the form for a new route or version (stations, mandatory, distances, road segments, date);
  * the versions waiting for a decision;
  * the carriers' requests.
* **Carrier, Routes:**
  * the new service picks a route of the network, ticks the stations served (mandatory ones held) and gives the
    times and the fare ladder;
  * "Ask for a route" and the list of the carrier's requests.

Tests: `backend/tests/test_network_routes.py` (with `backend/tests/network_helper.py`); database checks under "Network
routes (1163)".
