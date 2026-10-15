# Administrative geography: governorates to neighbourhoods

Owner's request, October 2026. Migration `db/schema/1124_admin_geography.sql`; loader and API
`backend/app/modules/geo/`; platform page `frontend/src/pages/admin/Geography.tsx` ("Geography").

## Why

Routes are many and are the carriers' to open, so the platform must know every place first, once, in a standard
form: the country at the level of governorates, then their districts and sub-districts, then every city, town and
village, and the neighbourhoods of the cities. Then a route can be opened from or to any place without defining it
first. Places found by field surveys are added later under the same scheme.

## The source: the United Nations' common operational dataset

The owner supplied `syr_humanitarian_locations_20200816.xlsx`, published by OCHA (the common operational datasets of
administrative divisions and populated places, "P-codes"). Studied in full:

| Sheet | Rows | Content |
|---|---|---|
| admin1 | 14 | governorates, `SY01` to `SY14` |
| admin2 | 62 | districts, `SY0100` (under their governorate) |
| admin3 | 272 | sub-districts (nahiya), `SY010000` (under their district) |
| Location | 8,007 | 7,593 communities `C1001`... and 414 neighbourhoods `N0001`..., each with its sub-district and position |
| city_neighbourhoods | 414 | the neighbourhoods of 13 cities and, for Damascus and Aleppo, the 18 areas of the city they are in |

Every row has an Arabic and an English name; every place has a latitude and longitude, all inside the country; no code
appears twice; every place's sub-district, every sub-district's district and every district's governorate exist.
Empty cells are written `<Null>` and are read as empty. Dates of last update run from 2016 to 2020. The workbook is
data published for re-use; the file itself is not kept in the repository (its names are Arabic data), it is loaded by
the platform.

## The model

- `ref.admin_area`: level 1 governorate, 2 district, 3 sub-district; code, parent, Arabic and English names, valid-on.
  The code's length follows the level and starts with the country.
- `ref.place`: a community (city, town, village) in a sub-district, or a neighbourhood in a community (with the area of
  the city), with its position. Searchable by Arabic or English name (trigram indexes) or code.
- `ref.geo_source`: each load (publisher, file, SHA-256, what it held and changed, who loaded it).
- `ref.city.place_id`: the community a city of the network is; `net.station.place_id`: where a station stands.
- Everyone reads the geography; only the platform writes it (`geo.manage`). A place is never deleted: a newer file that
  no longer holds it retires it, since stations may stand in it.

## Loading

The platform's "Geography" page (or `POST /api/admin/geo/import`) takes the workbook, checks it whole (sheets,
columns, codes, hierarchy, positions inside the country, names) and loads nothing if anything is wrong, saying what
and where. A good file is loaded in one transaction (about four seconds for the 8,355 rows): new places are added,
changed ones updated, missing ones retired; the same file twice changes nothing. The cities already in the network are
linked to their places (Damascus `C1001`, Aleppo `C1007`, Homs `C2528`, Hama `C2987`, Latakia `C3480`, Tartus
`C5221`, Idlib `C3871`, Daraa `C5993`, As-Suwayda `C6147`, Deir ez-Zor `C5086`, Al-Hasakah `C4360`, Raqqa `C5710`).

## Opening a place for routes

Any community can be opened for routes ("Open for routes"): it becomes a city of the network (`ref.serve_place`) with
a code of three letters and its country's time, linked to the place; carriers then set up stations and routes there as
anywhere else. A neighbourhood is not opened by itself: its city is, and a station records the neighbourhood it stands
in.

## API

- Public: `GET /api/geo/areas?parent=` (governorates, or what is under a code), `GET /api/geo/places?q=` (by name or
  code, with the way up to the governorate), `GET /api/geo/places/{pcode}` (with a city's neighbourhoods).
- Platform: `GET /api/admin/geo`, `POST /api/admin/geo/import`, `POST /api/admin/geo/places/{pcode}/serve`.

## Corridors and the direct routes today

The owner's answer to the trip-number question on corridors: routes are the carriers' to open and are many, so the
thousands of trip numbers stay grouped by kind of trip, not by geographic corridor. The direct intercity routes the
owner listed as running today: Damascus to Daraa, Homs, Aleppo, Hama, Idlib, Tartus, Latakia, As-Suwayda and
Al-Hasakah; Homs to Latakia, Damascus, Aleppo, Hama, Tartus, Idlib, Tadmor (Palmyra) and Deir ez-Zor; Aleppo to
Damascus, Idlib, Latakia, Qamishli, Deir ez-Zor and Raqqa. Tadmor (`C2889`, Homs governorate) and Qamishli (`C4564`,
written "Quamishli" in the file, Al-Hasakeh governorate) are opened for routes like any other community.

## The geography in use (1125)

The owner approved the next steps; migration `db/schema/1125_geography_in_use.sql`.

- **Places surveyed in the field.** A place the United Nations file does not hold (a new village, a neighbourhood of a
  town) is proposed by the platform (`ref.propose_place`, `POST /api/admin/geo/places`) with its sub-district (or its
  city, for a neighbourhood), names in both languages, position, the day of the survey and what was found. It gets a
  code of its own, `F` and five digits, apart from the United Nations' codes, so a newer United Nations file never
  touches it. It is checked: in its sub-district (by the boundary when loaded, else near the area's places), and not a
  like name within 2 km of a known place unless the surveyor says it is another place. It is used only once another
  person of the platform accepts it (`ref.review_place`, four eyes); a rejection says why. The platform's geography
  officers (role `PLATFORM_GEOGRAPHY`, permission `geo.manage`) do this apart from the administrators.
- **Boundaries.** The same publisher's boundaries of governorates, districts and sub-districts (COD-AB, GeoJSON with
  `ADM1_PCODE` to `ADM3_PCODE`) are loaded on the same page (`POST /api/admin/geo/boundaries`) onto
  `ref.admin_area.boundary`; a file naming an unknown area, or holding a shape that is not a polygon, loads nothing;
  the places lying more than 2 km outside their sub-district are reported. `GET /api/geo/areas/{pcode}/boundary` gives a
  boundary for a map.
- **Where a point lies.** `ref.locate` (`GET /api/geo/locate?lat=&lng=`) gives the sub-district holding a point and
  the nearest places with their distance.
- **Stations in their places.** The platform puts a new station in its place by searching a name, a code or a
  position: its city and position follow from the place, and a station of a city stands in that city's governorate;
  an existing station gets its place the same way (`PUT /api/admin/stations/{uid}/place`).
- **New cities named everywhere.** The web and the app name the cities of the network from the server
  (`GET /api/geo/cities`), so a city opened from the geography reads in Arabic and English at once.

## Corrected names (1127)

The owner asked that names be written as they are known locally and internationally. Migration
`db/schema/1127_place_name_corrections.sql`.

- Each place and area keeps its name as published (`published_en`, `published_ar`); the name shown is the published
  one with the platform's corrections (`ref.name_correction`): a word replaced by another, in English or Arabic, in the
  names under an area (a district, a governorate), of one place, or in the whole country. A correction is applied at
  once and again after every newer file, so it is never lost; the published name is still found by search, and the
  cities of the network take their place's corrected name.
- Set by the owner: Palmyra for the city of Tadmor alone (C2889; its district and sub-district stay Tadmor, and Bab
  Tadmor, a neighbourhood of Homs named so, keeps its name); Qamishli in its district (the town, the district, the
  sub-district and the villages named after it); the governorates as Latakia, Idlib, Al-Hasakah, Deir ez-Zor, Tartus,
  Raqqa, Daraa and As-Suwayda wherever their names appear; and, each in its own area, Manbij, Azaz, Jisr al-Shughur,
  Maarat al-Numan, Khan Shaykhun, Ras al-Ayn, Tell Abyad, Douma, Zabadani, Maaloula, Saydnaya, Bosra and Salamiyah.
  On the real file: 182 places and 48 areas.
- The platform manages them on the Geography page (Corrected names; `GET|POST /api/admin/geo/names`,
  `DELETE /api/admin/geo/names/{id}`); removing one gives the published names back.

## Next steps

- Loading the real boundaries file: the environment that built this could not reach the publisher; the platform loads
  it from the Geography page.

## The map of an area (1129 batch)

The Geography page browses the country as a list or as a map. The map (`GET /api/admin/geo/areas/{pcode}/map`, SY for
the whole country) draws, as plain SVG with no map tiles from outside, the area's boundary, the areas under it (each
opens its own map), its places (the communities of a sub-district; above that the cities of the network; places
proposed in the field in another colour) and the stations in it, found by their place or, without one, by the
boundary. Where no boundary is loaded, each area is placed at the middle of its places. Boundaries are simplified for
drawing (0.01° for the country down to 0.001° for a sub-district).
