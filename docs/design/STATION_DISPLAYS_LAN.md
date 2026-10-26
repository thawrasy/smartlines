# Station displays on a closed network (N46)

Owner's note (25 October 2026): the departure and arrival screens of a station are usually not on the internet. Like
airports and railway stations, a station runs them on its own local network (LAN), each screen driven by a small
computer or media player, and controls them from one place. The present way (a screen opens its link and is paired by
a short code, 1120 and 1129) needs every screen to reach the platform over the internet. It stays, for small stations
with a few screens on ordinary internet. This note adds the way for stations with a closed screen network.

## The answer in one line

One **station display hub** per station: a small server inside the station that alone talks to the platform (outbound
only), keeps the station's boards, and pushes them to the screens over the LAN. The screens never touch the internet;
the platform never reaches into the station.

```
 platform (cloud)  <── outbound HTTPS only (hub's own key) ──  station display hub  ── LAN / screens VLAN ──┬─ player 1 (Departures, gates)
                                                               (mini PC or VM)                               ├─ player 2 (Arrivals)
                                                                                                             ├─ player 3 (Bays 1-6)
                                                                                                             └─ IPTV channel (legacy TVs)
```

## The parts

1. **The hub**: a small Linux box (or a virtual machine on the station's server), with two network sides:
   * the uplink: only outbound HTTPS to the platform (no port opened from the internet, no VPN needed);
   * the screens side: the screens' network (a separate VLAN), where the hub is the only server.
   It runs the board application itself (the same pages as `/screen/{uid}`, built into the hub), a local store of the
   station's boards, layouts and media, and a push channel (WebSocket) to every player.
2. **The players**: whatever drives a screen: a mini PC, an Android TV box, or a smart TV's browser in kiosk mode. Each
   opens one fixed local address, `http://<hub>/screen/<screen code>`, and stays on it. Screens that cannot run a browser
   take an **IPTV channel**: the hub draws each board and sends it as a multicast video stream that set-top boxes tune to.
3. **The registry in the platform** (the station portal, under Screens): each screen with its code, kind (departures,
   arrivals, bays, information, advertising), place, **group**, its player's hardware address (MAC) and its fixed IP.
   The hub copies this registry and serves only the screens it lists.
4. **Central control (the CMS)**: in the platform, the station's administration designs layouts from templates, puts
   screens in groups (departure gates, arrivals hall, bays, advertising), and schedules playlists for the advertising
   screens. A change is sent to the hub, which applies it to the group at once.

## The owner's questions

* **Which organisational rule?** Screens are run like airport and railway displays: a closed network owned by the
  station, controlled from one place, no screen exposed to the internet. The hub satisfies it: the only link out is the
  hub's outbound connection, recorded and signed.
* **Is an IP address alone enough?** No. An IP address can be taken by any device plugged into the network. A screen is
  accepted when three things match: its fixed IP, its hardware address (MAC), and a device key the hub gives the player
  the first time an administrator approves it. The hub is itself paired once with the platform by a one-time code
  entered by the station administrator, then holds its own key; the short code of today remains for that first step.
* **Are the addresses fixed?** They must be, and the station's network makes them so: the hub (or the station's router)
  hands out addresses by reservation (each player's MAC always receives the same IP). The platform keeps the plan and
  shows a mismatch (a screen seen at another address, or an unknown device asking) as an alert.
* **Who registers the address?** Nobody types it from scratch. A new player on the screens network announces itself to
  the hub; the hub lists it under "waiting" in the station portal with its MAC and IP; the station's administrator
  approves it and gives it a screen (kind, place, group). The station's IT person sets the reservation once. Every
  approval and change is recorded with who did it.

## When the internet is down

The hub keeps showing the last boards it has, with the time of the last update in a corner, and moves trips on by their
scheduled times (a trip past its time without news is shown as "see the counter"). Changes made at the station's
counters during the outage reach the hub over the station's own network if the counters are on it. When the uplink
returns, the hub catches up and reports how long it was cut off. Screens report to the hub every 30 seconds; a silent
screen raises the "screen not seen" alert of 1129 through the hub.

## Security

* The hub accepts nothing from the internet. Its outbound connection uses TLS (verified against the system's
  certificate authorities, or the station's own with `MASSLAK_HUB_CA`) and the hub's own key, which the platform can
  revoke.
* The screens VLAN carries no other traffic; players are locked in kiosk mode and accept only the hub's push.
* The hub shows only public board data (trip number, destination, time, bay, status): no passenger data is on it.

## What is built (1179)

| Part | Where | What it does |
|---|---|---|
| Database | `db/schema/1179_station_display_hub.sql` | `net.display_hub` (station, name, SHA-256 of the hub's key, last contact, version, revocation with reason), `net.hub_pairing` (one-time code kept as a hash, one hour, used once), `net.hub_player` (players waiting, approved or rejected), `net.hub_event` (unknown device, player at another address at most once an hour, rejected device asking again, uplink back after a cut of 60 s or more; never changed). `net.station_screen` gains its hub, screen code, group, MAC and fixed IP (MAC and IP set together, only with a hub). |
| Platform API | `backend/app/modules/boarding/hubs.py` | Station portal `/api/station/hubs` and platform `/api/admin/boarding/stations/{station}/hubs`: hubs, pairing code, revoke, waiting players (approve for a screen or reject), a screen's code, group and fixed IP, release of a player. The hub's own door `/api/hub` (`pair`, `sync`, `report`), authenticated by the `X-Hub-Key` header only. |
| Screens in the portals | `frontend/src/pages/station/Hubs.tsx` | Under Screens in the station portal and in the platform's Boarding page: add a hub (shows the code once), the waiting players with MAC and IP, the screens' network identity, the hub's reports. |
| The hub | `hub/` (container image), `deploy/hub-install.sh` | Pairs with the code (the key is made on the hub; only its hash leaves it), pulls the boards every 15 s, reports the players it sees every 30 s, serves `/screen/<code>` to the players with a WebSocket push and polling as fallback, strict CSP. A player is shown a board only when its MAC (from the hub's ARP table), fixed IP and device key cookie all match; a new player sees a "waiting for approval" page with its MAC and IP. Board labels and city names in both languages come from the platform with each pull. |
| Offline | `hub/masslak_hub/board.py` | Without news for 120 s the board shows "Connection lost · last updated hh:mm"; a trip past its time that is not final is shown as "See the counter". When the uplink returns the hub reports how long it was cut. |
| Tests | `db/tests/run_tests.sql` (1179), `backend/tests/test_display_hub.py`, `hub/tests` (CI security job) | Pairing once, key by hash, report checks, address mismatch, kept events, the API end to end, the hub's player checks and offline board. |

Install on the station's box (Docker, outbound HTTPS to the platform):

```
sudo ./deploy/hub-install.sh --platform https://<platform> --code <code from the portal> --listen <hub's IP on the screens VLAN> [--port 8080]
```

Each player then opens `http://<hub>:8080/screen/<screen code>` in kiosk mode. The station's IT person reserves a fixed
IP for each player's MAC in the hub's or router's DHCP.

### Not built yet

* Layouts from templates, groups driving layouts, and advertising playlists (the CMS of "The parts", point 4).
* The IPTV multicast channel for screens without a browser.
* Counter changes reaching the hub over the station's network while the uplink is down (the hub shows its last boards).
* A DHCP reservation helper on the hub (the reservation is set by the station's IT person).

## Build order (as planned)


1. Database: hubs (paired with a station, key, last contact), the screen registry gains group, MAC, fixed IP and device
   key, and the waiting list of players; layouts, groups and playlists.
2. API: hub pairing and its pull (boards, registry, layouts, changes since), station portal pages for hubs, waiting
   players, groups and layouts.
3. The hub software: a container image (board pages, local store, WebSocket push, DHCP reservation helper, optional
   IPTV encoder), installed with one command on the station's box.
4. Tests, a run on a test network with two players and the uplink cut, the guide for the station's IT person.

The short-code pairing of 1129 stays for stations whose screens are on the internet.
