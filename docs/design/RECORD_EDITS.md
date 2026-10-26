# Records are edited, and every edit is kept (1170)

Owner's note (25 October 2026): some data could not be edited at all once saved. A route-by-route sweep of the API
found the records a portal could create but never change: vehicles, crew and their licences, stations, companies,
agencies, carrier routes and parcel points. Vehicles, crew and licences came first (1170); stations and companies
(carriers, agencies, station operating companies) followed (1171); carrier routes and parcel points are next.

## The rule

* A record is edited in place; the database keeps the history, field by field, with who changed it, when and why
  (`sys.tg_edit_history`, one trigger for every edited table, told by its arguments which fields it keeps).
* Regulated fields change only with a reason: a vehicle's plate, chassis and engine numbers; a person's names, birth
  date and national number. The reason is given on the row (`change_reason`) and moved into the history by the
  trigger; no session setting is trusted.
* What the platform or an authority holds stays theirs: a blocked or impounded vehicle and a blocked crew member are
  released by the platform, not by the carrier.
* A person's names and identity document are not copied into an append-only history: an erasure request must be able
  to remove them. Their corrections stay in the activity log, which redacts them.

## Vehicles and crew

* `PATCH /api/carrier/vehicles/{uid}` and `GET /api/carrier/vehicles/{uid}` (details, licences, history);
  `fleet.vehicle_change` keeps every edit.
* `PATCH /api/carrier/crew/{uid}`: names, birth date and national number with a reason; kind, licence class, mobile
  and status freely; `fleet.crew_change` keeps the profile's edits.
* Screens: an Edit button on the Fleet and Drivers pages, with the vehicle's licences and history of changes.

## Stations and companies (1171)

* `PATCH /api/admin/stations/{uid}` and `GET /api/admin/stations/{uid}`: name and position with a reason (tickets and
  boards show them), address, contacts, licence, lead time and status; `net.station_change` keeps every edit.
* `PATCH /api/admin/companies/{uid}` and `GET /api/admin/companies/{uid}`: legal name, registration and licence numbers
  with a reason, their dates and the regulator's code; `iam.company_change` keeps every edit, the legal name included
  (it is on the company's party, whose trigger fires for companies only). A status change records its reason there too.
* Screens: an Edit button on the Companies, Travel agencies and Stations pages, with the history of changes; one shared
  editor (`components/RecordEditor.tsx`) takes the fields each page lists.

## Licences

A saved licence stays locked (study 4.18): its number and dates change through a correction request that two people
of the platform other than the one who asked review and approve (030, 1054). Approving it now applies the new values
to the licence (`fleet.tg_license_change_apply`); before 1170 an approved request changed nothing. A renewal is a new
licence record, and the old one stays.

* `POST /api/carrier/vehicles/{uid}/licences`: a new or renewed licence of a vehicle (crew licences already had one).
* `POST /api/carrier/licences/{uid}/change-request`: a correction, reviewed and approved on the platform's Fleet and
  trip records page.

## What stays frozen, and why

Issued tickets, e-invoices, ledger entries, closed roadside checks, revoked placards and histories are never changed:
they are records of what happened, and law or audit requires them as they were. A mistake there is corrected by a new
record that refers to the old one (a refund, a credit note, a reversal).
