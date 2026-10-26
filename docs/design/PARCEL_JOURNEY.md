# A parcel's journey after it is handed over: on board, through the carrier's locations, collected or delivered

Review of the parcel system and the owner's note on the parcel journey, 26 October 2026. Built in migrations 1182 and 1183
(`db/schema/1183_parcel_routes.sql`), on top of 1182 (`db/schema/1182_parcel_journey.sql`), the module
`backend/app/modules/parcels/journey.py`, the notices in `backend/app/modules/notify/catalog.py`, the carrier's tabs
"On board and arrived" and "Waiting for recipients" (`frontend/src/pages/carrier/ParcelJourney.tsx`, on the Parcels
page) and "Follow" on the sender's list of parcels.

## What the review found

Parcels on scheduled trips (N5, 1147) went from booking to the counter: reserved, paid, handed over, labelled. The
tables for the rest of the journey existed in the database (tracking milestones, delivery attempts and proofs, cash on
delivery), but no endpoint or screen used them for trip parcels: nothing recorded the parcel going into the hold, nobody
told the sender it had arrived, the recipient had no safe way to prove the parcel was theirs, and a damaged, refused or
uncollected parcel had no record.

## The journey

| Step | Who | What the system checks | Status, milestone |
|---|---|---|---|
| On board | carrier's staff scan the label (or type the tracking number) | handed over; not already on board; on the trip being loaded when the clerk names it | `IN_NETWORK`, `LOADED` |
| Arrived | staff at the destination scan it again | loaded first; not arrived twice | `ARRIVED`; the pickup code goes out |
| Collected | the clerk enters the recipient's code, or checks an identity document | waiting at its station; the code's hash matches; tries left | `DELIVERED`, `DELIVERED` (OTP or ID) |
| Problem | the clerk records damaged, missing, refused or not collected | refused and not collected only at the station; not collected only after the policy's days | `EXCEPTION`, `EXCEPTION` |
| Sent back | the clerk, after a problem is recorded | a problem recorded; not delivered | `RETURNED`, `RETURNED` |

The order is also a check on the shipment table (`shipment_journey_ck`): no arrival before loading, no delivery before
arrival, never both delivered and returned, a returned parcel always has its recorded problem, and an arrived parcel
always holds the hash of its code. A database test reads the check.

## The pickup code

- Six digits, drawn from the parcel's tracking number and the moment it arrived with a key derived from the platform's
  signing secret. The same code is shown each time; it is **never stored**. The shipment keeps only a keyed hash.
- The sender sees it in "Follow" while the parcel waits; the recipient's mobile is texted it on arrival together with
  the station. The notice's outbox row does not hold it: the notification worker draws it again when it sends.
- A wrong code counts a try, kept even though the request is refused. After the policy's limit (`pickup_code_tries`,
  5) only an identity check hands the parcel over; the clerk records which document (its kind and last digits), and
  the proof of delivery says `ID` with that note.
- Cash on delivery, when the parcel has an amount, is recorded as collected by the clerk at hand-over.

## Waiting and returns

The "Waiting for recipients" tab lists the carrier's arrived parcels not yet collected or returned, with the days each
has waited. After the policy's `unclaimed_days` (7) the row is marked overdue and "Not collected" becomes available;
then the parcel can be sent back to its sender. Both values are in the platform's parcel policy (`parcels.policy`).

## Notices

| Event | Sender's account (in-app and email) | Recipient's mobile (SMS) |
|---|---|---|
| `parcel.arrived` | arrived at the station, the code, the days it waits | the code and the station |
| `parcel.delivered` | handed to whom, with the code or after an identity check | |
| `parcel.exception` | what was recorded and the clerk's note | |

The events are internal (not offered to partners' webhooks), so they need no published schema.

## Permissions

The carrier's endpoints need the operator portal and `shipping.operate` or `parcels.counter`; each acts on the
carrier's own parcels only. The sender's journey endpoint returns only the sender's own parcels; another passenger gets
"not found".

## Tests

`backend/tests/test_trip_parcels.py`: the whole journey with a wrong code then the right one; locked codes needing an
identity check; an unclaimed parcel recorded after its days and sent back; damage recorded on board; a passenger refused
the carrier's endpoints. `db/tests/run_tests.sql`: the journey check, no code column, the policy's values.

## Through the carrier's locations, delivery to an address, important parcels (1183)

The owner's note: a carrier may have several locations between A and Z. The parcel is received at B, sent on to C, and so
on to Z; arrival at Z is announced to the sender; the code goes to the recipient's mobile when the parcel is ready to be
collected (or the clerk sends it at the recipient's request); delivery to an address is a setting; without the code the
identity document is checked and recorded; an important parcel needs verification and close tracking.

### Locations on the way

| Step | Endpoint | Rule |
|---|---|---|
| Received at a location | `POST /scan/receive {point_uid}` | loaded, not arrived, not already held at a location; if the previous location named the next one, only that one receives it |
| Sent on | `POST /scan/dispatch {next_point_uid?}` | held at a location; the next location, or none for the destination |
| Arrived | `POST /scan/arrive` | refused while the parcel is held at a location |

Locations are the carrier's parcel points (its stations and offices). Each is a row of `ship.parcel_hop` (received, sent
on, to where); a unique index keeps a parcel at one location at a time. Milestones `RECEIVED_AT_HUB` and `DEPARTED`
carry the location's name; the carrier's "Waiting" tab lists the parcels held at each location, and the sender's
"Follow" shows the locations passed.

### Collected at the counter, or taken to an address

- The carrier's settings: "We also take parcels to the recipient's address" (`address_delivery`, off by default) and its
  fee (`address_fee`, added to the price and shown in the price breakdown).
- The sender (online or at the counter) chooses "Collected at the counter" (the default) or, when the carrier offers it,
  "To the address" with the address. The database keeps the address with the mode.
- **Collected:** the code is issued on arrival and texted to the recipient; the clerk can send it again
  (`POST /{tracking_no}/send-code`, at most `code_sends` times, 3).
- **To the address:** arrival is announced without a code. `POST /{tracking_no}/out` issues a new code, texted to the
  recipient, who gives it to the courier. `POST /{tracking_no}/attempt-failed {reason}` records the failed attempt
  (nobody home, wrong address, refused at the door, no code, not reachable, other) and brings the parcel back to the
  station; its code is withdrawn and the next departure issues a new one. The parcel is handed over only on its way.

### The identity check, field by field

`deliver` takes `id_check {doc_kind, doc_no, holder_name, issued_by?}` instead of a free note. `ship.parcel_id_check`
keeps the document's kind (national ID, passport, family book, residence permit, driving licence, other), its number
encrypted with the platform's field keys (only its last four digits in clear), the holder and the issuer, the clerk and
the time. The sender sees the kind, the last four digits and the holder. The table is in the restricted "ship personal
records" dataset (pseudonymised after five years).

### Important parcels

The sender ticks "Important parcel", or the platform sets an amount of declared value from which every parcel is
important (`secure_from_value`, off by default). An important parcel is handed over only with **both** the recipient's
code and an identity check (the identity check alone once the code is locked by wrong tries), and its sender is told of
every step by e-mail as well as in the app; other parcels' senders see every step in the app.

### Notices added

| Event | Sender | Recipient (SMS) |
|---|---|---|
| `parcel.moved` (on board, at a location, failed attempt) | in-app; e-mail too for an important parcel | |
| `parcel.arrived` for an address | arrived, will be taken to the address | arrived, the code comes when it leaves |
| `parcel.out_for_delivery` | on its way, the code | the code for the courier |
| `parcel.code_sent` | | the code again |

### Tests (1183)

`test_trip_parcels.py`: locations in order (wrong location, skipping the sending-on and arriving while held refused);
the code sent again three times at most and never in the outbox; delivery to an address (refused while the carrier does
not offer it, the fee, no code at arrival, a failed attempt and a new code, handed over on the way); an important parcel
refused with the code alone and with the identity alone. `run_tests.sql`: the journey check for addresses, one location
at a time, the gates and no clear document number.
