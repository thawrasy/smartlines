# Station display hub (N46)

A small server inside a station that alone talks to the platform (outbound HTTPS) and serves the departure and arrival
boards to the screens' players on the station's closed network. Design and status: `docs/design/STATION_DISPLAYS_LAN.md`.

## Install

On the station's box (Linux with Docker; outbound HTTPS to the platform; one side on the screens' VLAN):

```
sudo ./deploy/hub-install.sh --platform https://<platform> --code <code> --listen <hub IP on the screens VLAN> [--port 8080]
```

The code is made under Screens → Display hubs in the station portal, valid one hour, used once. The hub makes its own
key and sends only its SHA-256; the station's administration can revoke the hub at any time.

## Players

Each player (mini PC, Android TV box, smart TV browser in kiosk mode) opens `http://<hub>:8080/screen/<screen code>`.
A new player shows its MAC and IP and waits; the station's administration approves it for a screen in the portal.
Afterwards the player is shown its board only while its MAC, fixed IP and device key all match. Reserve a fixed IP for
each player's MAC in the DHCP of the hub or the router.

## Run by hand

```
python -m masslak_hub --state /var/lib/masslak-hub pair --platform https://<platform> --code <code>
python -m masslak_hub --state /var/lib/masslak-hub serve --host <hub IP> --port 8080
```

| Variable | Meaning |
|---|---|
| `MASSLAK_HUB_CA` | A certificate authority file for the platform's TLS (a station's own authority) |
| `MASSLAK_HUB_ALLOW_HTTP` | Allow a plain-HTTP platform address (test benches only) |
| `MASSLAK_HUB_HOST`, `MASSLAK_HUB_PORT` | Listening address and port (defaults: all addresses, 8080) |
| `MASSLAK_HUB_ARP` | Another ARP table file (test benches only) |

## Tests

```
pip install -r requirements.txt pytest && python -m pytest tests
```
