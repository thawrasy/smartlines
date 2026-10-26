# A parcel's journey after it is handed over: on board, arrived, collected

Review of the parcel system, 26 October 2026. Built in migration 1182 (`db/schema/1182_parcel_journey.sql`), the module
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
