# Know your customer for every party

Owner's request N14, migration `1159_party_kyc.sql`. It builds on the company KYC of `COMPANY_KYC.md` (1118).

## Who fills what

| Party | Form | Where | Reviewed by |
|---|---|---|---|
| Carrier | `CARRIER` (the 1118 form) | carrier portal, Know your customer | the review stages of `kyc.review_stages` |
| Agency | `AGENCY` | agency portal, Know your customer | the same stages |
| Station operating company | `STATION` | station portal, Know your customer | the same stages |
| Driver | `DRIVER` | driver app, My verification | one compliance reviewer |
| Passenger | `PASSENGER` | account, Know your customer | one compliance reviewer |

`iam.kyc_form.subject_kind` names the kind of a form. Each kind has its own versions, one draft and one version in force
at a time, so changing the agencies' form leaves the carriers' alone. A company follows the form of its kind
(`iam.kyc_kind_of_company`): an agency fills the agency form, a station operating company the station form, every other
company the carriers' form.

## The company forms

The agency and station forms reuse the carriers' identity, contacts, ownership (beneficial owners and signatories),
screening, financial and tax questions. Each also has questions of its own:

* agency: licence number, issuer and expiry, accreditation, the services it sells, its sales channels, branches and
  sub-agents; documents: commercial register, agency licence, tax certificate, identity document;
* station operating company: who owns the station, its operating permit, the site (name, address, bays, counters,
  departures a day, carriers served, facilities, hours, security) and the fees it charges; documents: commercial
  register, tax certificate, identity document.

Station operating companies now upload documents on their own documents page, as carriers and agencies do.

## Persons

A driver's or passenger's file (`iam.person_kyc`) holds their identity document (the number is encrypted, bound to the
person and the field), birth date and place, residence, and declarations. A driver also gives an emergency contact, their
years of professional driving, licence classes, previous employers, violations and accidents. A person's form asks for no
company documents (refused by the database).

* The person opens, fills and submits their own file. A new version starts from the approved answers.
* One reviewer holding `kyc.review.compliance` approves, returns with the fields to correct, or rejects with a reason.
  The person who entered the file never decides it (a check on the table, and the reviewer's own file is refused too).
* Submitting makes the person `PENDING`. Approval makes them `VERIFIED` (`iam.party.verification_status`) until the file
  is due for review. Return or rejection without an earlier approved file makes them `UNVERIFIED` or `REJECTED`.
* Opening a file and showing the document number are recorded in the data access log; showing it needs a reason.

## What verification unlocks

The setting `kyc.persons` holds:

```json
{"required_before": {"PASSENGER": [], "DRIVER": []}, "review_months": {"PASSENGER": 60, "DRIVER": 24}}
```

Nothing is locked at launch. When the platform turns them on:

* `LOYALTY_REDEEM`: a passenger redeems points only once verified (a trigger on `pricing.points_ledger`);
* `DRIVE`: a driver is put on a trip only once verified (a trigger on `ops.crew_assignment`).

Companies keep their own gates of 1118 (`kyc.required_before`: publishing trips, payouts).

## API

* `GET|POST|PUT /api/agency/kyc...` and `/api/station/kyc...`, the same four routes as `/api/carrier/kyc`.
* `GET /api/account/kyc`, `POST /api/account/kyc/open`, `PUT /api/account/kyc/{uid}`, `POST /api/account/kyc/{uid}/submit`
  for drivers and passengers.
* `GET /api/admin/person-kyc?status=&kind=`, `GET /api/admin/person-kyc/{uid}`, `POST .../decide`, `POST .../reveal`.
* `GET|PUT /api/admin/kyc/form?kind=` for the form of each kind; `PUT /api/admin/kyc/settings/persons`.

## Screens

* Agency and station portals: Know your customer (the company page of 1118) and Documents.
* Passenger: a card on the account page and the Know your customer page; driver: a My verification tab.
* Platform, Know your customer: a Drivers and passengers tab (list, file, decision), a kind selector on the form tab,
  and the drivers' and passengers' switches on the settings tab.

Tests: `backend/tests/test_party_kyc.py`; database checks under "Party KYC (1159)".
