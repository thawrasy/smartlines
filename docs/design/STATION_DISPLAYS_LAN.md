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

* The hub accepts nothing from the internet. Its outbound connection uses TLS with the platform's pinned key and the
  hub's own key, which the platform can revoke.
* The screens VLAN carries no other traffic; players are locked in kiosk mode and accept only the hub's push.
* The hub shows only public board data (trip number, destination, time, bay, status): no passenger data is on it.

## Build order

1. Database: hubs (paired with a station, key, last contact), the screen registry gains group, MAC, fixed IP and device
   key, and the waiting list of players; layouts, groups and playlists.
2. API: hub pairing and its pull (boards, registry, layouts, changes since), station portal pages for hubs, waiting
   players, groups and layouts.
3. The hub software: a container image (board pages, local store, WebSocket push, DHCP reservation helper, optional
   IPTV encoder), installed with one command on the station's box.
4. Tests, a run on a test network with two players and the uplink cut, the guide for the station's IT person.

The short-code pairing of 1129 stays for stations whose screens are on the internet.
