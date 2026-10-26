# Driver and crew details (owner's request N3, migration 1158)

## What it adds

A carrier now enters each crew member with the same care as a passenger's identity. Crew members are drivers,
hosts and assistants.

- **Name in parts**: first, father's, grandfather's (optional) and family names, and the mother's name (optional). These
  are the same name parts as the sign-up form (1149).
- **National number**: encrypted on the person (`iam.party.id_no_enc`), with a blind index so the same number cannot
  belong to two people, and its last four characters for display.
- **Sign-in**: a driver gets an account for the driver app, with a temporary password that is replaced at the first
  sign-in (1150). A host or assistant gets one only when given an e-mail.

## Licences

Every crew member carries licences in `fleet.license_record` (subject `DRIVER`, which covers every crew kind):

| Licence | Code |
|---|---|
| Driving licence, with its class (B, C, D, E…) | `DRIVING` |
| Heavy vehicle licence | `HEAVY_DRIVING` |
| Transport authority licence | `TRANSPORT` |
| Traffic department permit | `TRAFFIC` (new in 1158) |
| Cross-border permit, medical and first-aid certificates, criminal record, other | `CROSS_BORDER`, `MEDICAL`, `FIRST_AID`, `CRIMINAL_RECORD`, `OTHER` |

- Each licence has a stable `uid` (new in 1158), a number, an issuer, an issue date and an expiry date. A new licence
  waits for platform review (`PENDING_REVIEW`), as other licences do.
- Pictures of the front and back faces are stored like every company document: encrypted, scanned before anyone can
  open them, and reviewed by the platform. They are kept in `iam.document` (owner `LICENSE`, types `LICENSE_FRONT` and
  `LICENSE_BACK`) and linked from the licence (`document_id`, `back_document_id`).

## The platform's switches (`crew.licences`)

| Key | Launch value | Meaning |
|---|---|---|
| `required` | drivers: `DRIVING`; hosts and assistants: none | The licences each crew kind must hold |
| `refuse_missing` | `false` | Refuse a crew member on a trip when a required licence is missing |
| `refuse_expired` | `false` | Refuse a crew member on a trip when a required licence has run out on the trip's day |

- `fleet.crew_licence_problems(person, day)` lists what is missing (`MISSING:type`) or has run out (`EXPIRED:type`).
  Suspended licences do not count.
- The crew page shows these problems as warnings whatever the switches say.
- When a switch is on, the trigger on `ops.crew_assignment` refuses the assignment with `CREW_LICENCE`.

## API (carrier portal)

- `GET /api/carrier/crew`: crew members with their kind, the last four characters of the national number, the licence
  problems and the next expiry.
- `POST /api/carrier/crew`: add a crew member. Older clients that send `full_name` still work.
- `GET /api/carrier/crew/{uid}`: details and licences.
- `POST /api/carrier/crew/{uid}/licences`: add a licence.
- `POST /api/carrier/crew/{uid}/licences/{licence}/images/{front|back}`: a picture of one face.

## Tests

- `backend/tests/test_crew_details.py` covers:
  - a host without a sign-in, with the name in parts and an encrypted national number that cannot be reused;
  - a driver's licence with its class and front picture;
  - required licences reported as missing or expired;
  - another company's portal kept out.
- `db/tests/run_tests.sql`, block "Crew details (1158)", covers:
  - missing and expired licences;
  - the licence class form;
  - with the switches off, a crew member is warned but not refused;
  - with `refuse_expired` on, the assignment is refused.
