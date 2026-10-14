# Station display screens: Departures and Arrivals apart

Owner's decision, October 2026. Built in migration 1120 (`db/schema/1120_station_screens.sql`).

## What the owner asked

In the station portal, separate screens for the trips that leave and the trips that arrive. Each screen is named by its
word, "Departures" or "Arrivals", and shows on a screen of its own. The platform decides which ones a station shows; the
station's administration assigns display screens to each kind and distributes them independently.

## How it works

| Who | Does what | Where |
| --- | --- | --- |
| The platform | Allows the kinds a station shows: Departures, Arrivals, and Departures and arrivals on one board (the board the station had before, 1112). At least one. | Platform portal, Boarding stations, a station's settings (`display_kinds`) |
| The station's administration (1115) | Registers screens: a kind among those allowed, a place, a link of its own. Changes the kind or the place, stops and starts a screen, takes it down. | Station portal, Screens (`/station/screens`), owner or `station.screens` |
| The platform, where a station has no administration | The same | Platform portal, Boarding stations, a station's Screens |
| The display | Opens its link full screen; reads its board every 20 seconds | `/screen/<screen uid>` |

A screen's link is its uid: whoever holds it sees that screen's public board, which carries no passenger data. A link
taken down stops working; a stopped screen shows that it shows nothing at the moment.

## The screen

- Its word heads it in large type, in the colour of its kind (gold for departures, green for arrivals), with the station's
  name, its code and the screen's place, and the clock. The word changes with the languages the board shows in turn
  (Arabic and English every 10 seconds unless the platform sets otherwise, 1115), keeping the layout of the first.
- A departures screen lists the departures of the next 12 hours (destination, the stops on the way, carrier and logo,
  trip number, bay, state); an arrivals screen the arrivals of the next 6 (origin, the stops on the way, carrier, trip
  number, bay, Expected or Arrived). Up to 60 rows each.
- When the connection drops, the last board stays up with the time it was last updated.

## Data

- `net.station_boarding.display_kinds text[]`: the kinds allowed, `{DEPARTURES,ARRIVALS,COMBINED}` by default.
- `net.station_screen`: uid (the link), station, kind, place (`label`, unique in the station, 1 to 60 characters),
  active, `last_seen_at` (to the minute), who created and last changed it. Platform data by row security; the
  administration reads and writes it through its functions only (`net.station_screens`, `net.add_station_screen`,
  `net.change_station_screen`, `net.remove_station_screen`), which check that the caller administers the station
  (`net.station_bays_by_caller`, 1115). Changes of kind, place and state are captured in the audit trail; a screen reading
  its board is not.
- `brd.station_board(station uid, kind)`: the board of one kind (`COMBINED` by default, as before); NULL where the kind
  is not allowed. `brd.screen_board(screen uid)`: the board of one screen with its kind and place, marking it seen.

## API

    Station operating company (owner or station.screens)
    GET    /api/station/screens?station_uid=
    POST   /api/station/screens                  {station_uid, kind, label}
    PATCH  /api/station/screens/{screen_uid}     {kind?, label?, active?}
    DELETE /api/station/screens/{screen_uid}
    Platform (boarding.manage): the same under /api/admin/boarding/stations/{station_uid}/screens
    Public: GET /api/public/screens/{screen_uid}

## Not done (possible next steps)

- A screen for one hall's bays only (for example bays B001 to B010), or for one carrier.
- Pairing a display by a short code typed on it instead of opening its link.
- An alert when a screen stays unseen during opening hours.
