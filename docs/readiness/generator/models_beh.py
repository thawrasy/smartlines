"""Behaviour models: state, sequence and activity diagrams in Mermaid, beyond ST-1 to ST-6 and SQ-1 to SQ-4 of models.py.

States follow the CHECK constraints of the tables and the functions that move them (the module named in each title);
activities follow the routes and checks of the code at commit b983b22; ST-12 to ST-15, SQ-8 to SQ-10 and AC-7 to AC-9
were added for schema files 1100 to 1112 (commit c7528af)."""

STATES2 = {
    "ST-7": ("Company withdrawal (payouts)", """stateDiagram-v2
  direction LR
  [*] --> REQUESTED: carrier asks, amount held
  REQUESTED --> APPROVED: approved by finance (not the requester)
  APPROVED --> APPROVED: second approver above the limit (a different person)
  APPROVED --> PAID: paid out by a third officer, bank reference and ledger entry
  REQUESTED --> REJECTED: rejected with a reason, hold released
  APPROVED --> REJECTED: rejected with a reason, hold released
  APPROVED --> FAILED: table value, no route sets it yet
  PAID --> [*]
  REJECTED --> [*]"""),
    "ST-8a": ("Trip manifest", """stateDiagram-v2
  direction LR
  [*] --> DRAFT
  DRAFT --> ISSUED: issued and signed (domestic)
  DRAFT --> SUBMITTED: issued and sent to a border authority
  SUBMITTED --> ACKNOWLEDGED: border answers OK
  SUBMITTED --> REJECTED: border answers DENY
  ISSUED --> SUPERSEDED: amended, a new version is issued
  SUBMITTED --> SUPERSEDED: amended, a new version is issued
  ACKNOWLEDGED --> [*]"""),
    "ST-8b": ("Manifest delivery to one authority", """stateDiagram-v2
  direction LR
  [*] --> PENDING
  PENDING --> AVAILABLE: ready for the authority to pull
  PENDING --> SENT: pushed to the authority
  AVAILABLE --> ACKNOWLEDGED: receipt confirmed
  SENT --> ACKNOWLEDGED: receipt confirmed
  SENT --> REJECTED: refused with a reason
  SENT --> FAILED: not delivered
  FAILED --> MANUAL: delivered by hand, marked done
  ACKNOWLEDGED --> [*]"""),
    "ST-9a": ("Price offer for a parcel", """stateDiagram-v2
  direction LR
  [*] --> REQUESTED: customer asks the carrier for a price
  REQUESTED --> OFFERED: carrier prices it, valid until a time
  REQUESTED --> DECLINED: carrier declines
  REQUESTED --> WITHDRAWN: customer withdraws
  OFFERED --> ACCEPTED: customer books at the price
  OFFERED --> EXPIRED: validity passed
  OFFERED --> WITHDRAWN: customer withdraws
  ACCEPTED --> [*]"""),
    "ST-9b": ("Shipment (the states of ship.shipment)", """stateDiagram-v2
  direction LR
  [*] --> EXPECTED: pre-alert from a partner
  [*] --> CREATED: parcel booked on a trip, hold space checked
  EXPECTED --> CREATED
  CREATED --> PICKED_UP
  PICKED_UP --> IN_NETWORK
  IN_NETWORK --> OUT_FOR_DELIVERY
  OUT_FOR_DELIVERY --> DELIVERED
  OUT_FOR_DELIVERY --> EXCEPTION: failed attempt
  EXCEPTION --> OUT_FOR_DELIVERY: next attempt
  EXCEPTION --> RETURNED
  CREATED --> CANCELLED
  DELIVERED --> [*]"""),
    "ST-10a": ("Cash remittance from a carrier", """stateDiagram-v2
  direction LR
  [*] --> PENDING: recorded by finance, not more than owed
  PENDING --> CONFIRMED: confirmed by another person, ledger entry
  PENDING --> REJECTED: rejected by another person
  CONFIRMED --> [*]
  REJECTED --> [*]"""),
    "ST-10b": ("Settlement batch", """stateDiagram-v2
  direction LR
  [*] --> DRAFT: statement built
  DRAFT --> APPROVED: approved by someone other than its author
  APPROVED --> PAID: table value, no route sets it yet
  APPROVED --> DISPUTED: table value, no route sets it yet
  PAID --> [*]"""),
    "ST-11": ("Refund to the card", """stateDiagram-v2
  direction LR
  [*] --> PENDING: refund held, one idempotency key
  PENDING --> SUCCESS: provider accepts, posted to the ledger (stage DONE)
  PENDING --> FAILED: provider refuses or finance rejects, hold released
  PENDING --> PENDING: no answer, resent once by finance
  SUCCESS --> [*]
  FAILED --> [*]"""),
    "ST-12": ("Counter check-in at a boarding station (brd.station_checkin, 1105)", """stateDiagram-v2
  direction LR
  [*] --> CHECKED_IN: counter check, right, window and references pass, boarding pass with the bay
  CHECKED_IN --> CHECKED_IN: the same ticket again returns the same pass
  CHECKED_IN --> CANCELLED: cancelled at the counter with a reason, before boarding
  CHECKED_IN --> [*]: ticket BOARDED at the bay
  CANCELLED --> [*]"""),
    "ST-13": ("E-invoice document (acct.einvoice_document, 1104 and 1108)", """stateDiagram-v2
  direction LR
  [*] --> DRAFT: built by the worker for a paid booking, lines and taxes
  DRAFT --> FINALIZED: gapless number, chained hash, signature with its key id, QR
  DRAFT --> CANCELLED_DRAFT: dropped before it is final
  FINALIZED --> FINALIZED: a refund issues a credit note, a new document naming it
  FINALIZED --> SUBMITTED: table value, submission to the tax authority not built
  FINALIZED --> [*]
  CANCELLED_DRAFT --> [*]"""),
    "ST-14a": ("Partner agreement (pricing.loyalty_agreement, 1107)", """stateDiagram-v2
  direction LR
  [*] --> DRAFT: written by one officer
  DRAFT --> ACTIVE: activated by another person, one active per partner and currency
  ACTIVE --> ENDED: ended at the end of its period, frozen once used
  ENDED --> [*]"""),
    "ST-14b": ("Voucher (pricing.reward_voucher, 1107)", """stateDiagram-v2
  direction LR
  [*] --> ISSUED: member spends points at a partner's offer, code shown once
  ISSUED --> USED: partner honours the code, the platform owes its share
  ISSUED --> CANCELLED: member cancels, points returned
  ISSUED --> EXPIRED: validity passes or the partner ends, points returned
  USED --> [*]
  CANCELLED --> [*]
  EXPIRED --> [*]"""),
    "ST-14c": ("Partner statement (pricing.loyalty_settlement, 1107)", """stateDiagram-v2
  direction LR
  [*] --> DRAFT: drawn up for a period, each honoured voucher once
  DRAFT --> APPROVED: approved by another person
  DRAFT --> CANCELLED: cancelled, its vouchers go to the next statement
  APPROVED --> PAID: bank transfer recorded by a third person, ledger entry
  PAID --> [*]
  CANCELLED --> [*]"""),
    "ST-15a": ("Tracking alert (ops.tracking_alert, 1100)", """stateDiagram-v2
  direction LR
  [*] --> OPEN: departed trip silent past the set time, severity MEDIUM, carrier told
  OPEN --> OPEN: silence lasts, escalated to HIGH, carrier told again
  OPEN --> RESOLVED: positions come back
  RESOLVED --> [*]"""),
    "ST-15b": ("SOS (sec.sos_event, 1101)", """stateDiagram-v2
  direction LR
  [*] --> OPEN: driver or passenger on the trip presses SOS, carrier and platform told
  OPEN --> OPEN: the same person again returns the same SOS
  OPEN --> ACKNOWLEDGED: taken in hand by the carrier or the platform
  ACKNOWLEDGED --> CLOSED: closed with a note
  OPEN --> CLOSED: closed with a note
  CLOSED --> [*]"""),
    "ST-15c": ("Cancellation penalty (ops.trip_cancel_penalty, 1106)", """stateDiagram-v2
  direction LR
  [*] --> DUE: carrier cancels a trip while the regulator's penalty is on
  [*] --> COLLECTED: the carrier's balance covers it at once
  DUE --> COLLECTED: set off when the carrier next completes a trip
  DUE --> WAIVED: table value, no route sets it yet
  COLLECTED --> [*]"""),
}

SEQUENCES2 = {
    "SQ-5": ("Cancellation and refund", """sequenceDiagram
  autonumber
  actor P as Passenger
  participant A as API
  participant D as Database
  P->>A: POST /api/bookings/{ref}/cancel
  A->>D: lock the booking and its tickets
  alt a passenger has boarded, or the booking cannot be cancelled
    A-->>P: 409 CANNOT_CANCEL
  else paid in cash and the wallet is closed
    A-->>P: 409 CANCEL_AT_COUNTER
  else cancellable
    A->>D: refund per ticket from the fare brand schedule and the hours left
    A->>D: ledger entries, refund to the buyer's wallet, the rest to the carrier as a fee
    A->>D: agency keeps commission only on what is not refunded
    A->>D: tickets CANCELLED, seats released
    A-->>P: refund amount
  end"""),
    "SQ-6": ("Issuing a trip manifest", """sequenceDiagram
  autonumber
  actor S as Trip scheduler
  participant A as API
  participant D as Database
  participant G as Authority or border system
  S->>A: POST /api/carrier/trips/{uid}/manifests
  A->>D: trip published? (else 409 TRIP_NOT_PUBLISHED)
  A->>D: travellers, seats, documents, crew, cargo (international)
  A->>A: payload hash and signature
  A->>D: manifest ISSUED, or SUBMITTED for a border authority
  A->>D: one delivery per authority named in the manifest routes
  A-->>S: manifest with its hash
  G->>A: pull or receive the manifest
  G->>A: acknowledgement (or OK and DENY per person at the border)
  A->>D: delivery ACKNOWLEDGED or REJECTED, manifest status follows"""),
    "SQ-7": ("Company withdrawal with two approvers", """sequenceDiagram
  autonumber
  actor C as Carrier accountant
  actor F1 as Finance officer 1
  actor F2 as Finance officer 2
  actor F3 as Finance officer 3
  participant A as API
  participant D as Database
  C->>A: POST /api/finance/withdrawals
  A->>D: REQUESTED, amount held, needs_second if above the limit
  F1->>A: approve
  A->>D: APPROVED by F1 (not the requester)
  F2->>A: approve (only when above the limit)
  A->>D: second approver F2, different from F1
  F3->>A: mark paid with the bank reference
  A->>D: F3 is neither requester nor approver, else 403 FOUR_EYES
  A->>D: PAID, ledger entry posted"""),
    "SQ-8": ("Counter check-in and boarding at a station", """sequenceDiagram
  autonumber
  actor C as Counter clerk
  actor B as Bay staff
  participant A as API
  participant D as Database
  C->>A: POST /api/station/checkin (ticket code or number, document seen)
  A->>D: brd.station_checkin_ticket
  D->>D: station on, BOARDING_PASS right, own counter, ticket and stop, window, references
  alt a check fails
    A-->>C: 409 with its code (NOT_GRANTED, CHECKIN_CLOSED, REFERENCES_MISSING ...)
  else checked in
    D-->>A: boarding pass with the bay (the same pass if already checked in)
    A-->>C: pass to print, no photo while its legal basis is missing
  end
  B->>A: POST /api/station/board (scan at the bay)
  A->>D: brd.station_may_board: BOARDING right and a check-in at this station
  A->>D: the driver's boarding path: stop, photo rule, boarding record
  A-->>B: OK, DUPLICATE or the refusal"""),
    "SQ-9": ("A carrier cancels a trip", """sequenceDiagram
  autonumber
  actor S as Carrier
  participant A as API
  participant D as Database
  participant W as Worker
  S->>A: POST /api/carrier/trips/{uid}/cancel with a reason
  A->>D: lock the trip, refused while it carries parcels
  loop every paid booking
    A->>D: reverse every allocation line, refund in full to whoever paid
    A->>D: booking and tickets CANCELLED, seats released
  end
  A->>D: unpaid reservations end, crew released, ops.trip_disruption kept
  opt the regulator's penalty is on
    A->>D: ops.trip_cancel_penalty COLLECTED or DUE
  end
  A-->>S: refunds, reservations ended, penalty
  A->>D: event trip.cancelled for the carrier's integrations
  W->>D: credit notes for the invoiced bookings"""),
    "SQ-10": ("A voucher honoured at a partner and settled", """sequenceDiagram
  autonumber
  actor M as Member
  actor R as Partner
  actor F as Finance
  participant A as API
  participant D as Database
  M->>A: POST /api/loyalty/vouchers (offer of an active agreement)
  A->>D: points debited, voucher ISSUED, code kept encrypted
  A-->>M: the code, once
  R->>A: POST /api/v1/loyalty/vouchers/redeem (or an officer for it)
  A->>D: voucher USED, platform's share from EXPENSE to the partner's wallet
  F->>A: draw up the statement for a period
  A->>D: statement DRAFT with its lines
  F->>A: another officer approves it (four eyes)
  F->>A: a third records the bank transfer
  A->>D: PAID, partner wallet to bank clearing"""),
}

ACTIVITIES = {
    "AC-1": ("Counter cash sale and remittance", """flowchart TD
  A1([Customer at the carrier counter]) --> A2{Cash open for the counter, and the carrier under its cash limit?}
  A2 -- no --> A3[Refused: PAYMENT_METHOD_DISABLED or CASH_LIMIT_REACHED]
  A2 -- yes --> A4[Sell, take the cash, print the ticket]
  A4 --> A5[Cash owed by the carrier grows, ageing report]
  A5 --> A6[Finance records a remittance, never more than owed]
  A6 --> A7{Another officer confirms?}
  A7 -- yes --> A8([Ledger entry, the amount owed falls])
  A7 -- no --> A9([Remittance rejected])"""),
    "AC-2": ("Boarding at the bus door", """flowchart TD
  B1([Driver scans the ticket at the door]) --> B2{Online?}
  B2 -- no --> B3[Checked against the trip pack, queued, sent in a batch later]
  B3 --> B4{Older than the pack's validity?}
  B4 -- yes --> B5[Refused and logged]
  B4 -- no --> B6
  B2 -- yes --> B6{Signature, trip, stop and status valid, photo on file if a rule requires it?}
  B6 -- no --> B7([DENIED with the reason, logged])
  B6 -- yes --> B8([Ticket BOARDED, the first boarding moves the trip to BOARDING])"""),
    "AC-3": ("Reserve now, pay later", """flowchart TD
  C1([Passenger books with PAY_LATER]) --> C2{Option open, under the open reservations limit, before the cut-off?}
  C2 -- no --> C3[Refused with the reason]
  C2 -- yes --> C4[Booking PENDING_PAYMENT, tickets HOLD, pay_by set]
  C4 --> C5{What happens first?}
  C5 -- paid at the counter --> C6([Booking CONFIRMED, tickets ISSUED])
  C5 -- pay_by passes --> C7([Booking EXPIRED, tickets CANCELLED, seats released])
  C5 -- passenger cancels --> C8([Reservation cancelled, nothing to refund])"""),
    "AC-4": ("Onboarding a carrier to its first published trip", """flowchart TD
  D1([Carrier registers and uploads its documents]) --> D2[Files encrypted and scanned]
  D2 --> D3{Platform review}
  D3 -- rejected --> D4[Carrier corrects and resubmits]
  D4 --> D2
  D3 -- approved --> D5[Company ACTIVE]
  D5 --> D6[Vehicles with valid insurance and seat layouts, then drivers]
  D6 --> D7[Routes, stations and fares]
  D7 --> D8[Trips from templates, with a vehicle and an active driver]
  D8 --> D9([Publish: the trips are on sale])"""),
    "AC-5": ("A change to the photo policy", """flowchart TD
  E1([Privacy officer asks for a change]) --> E2{Value valid?}
  E2 -- no --> E3[Refused: INVALID_SETTING]
  E2 -- yes --> E4[Change PENDING with a copy of the current stages]
  E4 --> E5{Next stage: another officer approves?}
  E5 -- no --> E6([REJECTED])
  E5 -- yes --> E7{Last stage?}
  E7 -- no --> E5
  E7 -- yes --> E8([APPLIED, the legal document number is kept])"""),
    "AC-6": ("Daily finance close", """flowchart TD
  F1([Bank statement imported]) --> F2{Line matches a transfer top-up?}
  F2 -- yes --> F3[Credit the wallet once]
  F2 -- no --> F4[Match by hand, or ignore with a reason]
  F3 --> F5[Wallets reconciled with the ledger]
  F4 --> F5
  F5 --> F6{Any mismatch?}
  F6 -- yes --> F7([Alert: money mismatch, the on-call engineer is paged])
  F6 -- no --> F8[Ledger close of the day]
  F8 --> F9([Settlements and withdrawals, each approved and paid by separate officers])"""),
    "AC-7": ("SOS and incidents on a trip", """flowchart TD
  G1([Driver or passenger presses SOS]) --> G2{On this trip and the trip under way?}
  G2 -- no --> G3[Refused]
  G2 -- yes --> G4{An open SOS of the same person?}
  G4 -- yes --> G5[The same SOS is returned]
  G4 -- no --> G6[SOS OPEN with the position]
  G6 --> G7[Carrier owners and platform security told at once]
  G7 --> G8[Acknowledged, then closed with a note]
  G9([Driver reports an incident with evidence]) --> G10[Incident OPEN, linked to the driver's open SOS if any]
  G10 --> G12{Severe?}
  G12 -- yes --> G13[Vehicle out of service at once]
  G12 -- no --> G11
  G13 --> G11([Reviewed and closed by the carrier or the platform])"""),
    "AC-8": ("A passenger at a boarding station", """flowchart TD
  H1([Passenger at the station]) --> H2{Has a ticket?}
  H2 -- no --> H3{Counter holds the carrier's BOOKING right and is under its cash limit?}
  H3 -- no --> H4[Sent to another channel]
  H3 -- yes --> H5[Seats held, sold for cash, tickets printed]
  H5 --> H6
  H2 -- yes --> H6{Check-in window open and references on file?}
  H6 -- no --> H7[Refused with the reason]
  H6 -- yes --> H8[Document seen, boarding pass with the bay]
  H8 --> H9[Departure board shows the bay and the state]
  H9 --> H10{Scan at the bay: checked in here?}
  H10 -- no --> H11[CHECKIN_REQUIRED]
  H10 -- yes --> H12([Ticket BOARDED])"""),
    "AC-9": ("A carrier cancels a trip", """flowchart TD
  K1([Carrier decides to cancel]) --> K2{Trip published and no parcels on board?}
  K2 -- no --> K3[Refused, parcels moved to another trip first]
  K2 -- yes --> K4[Every paid booking refunded in full to whoever paid]
  K4 --> K5[Unpaid reservations end, seats and crew released]
  K5 --> K6{Regulator's penalty switched on?}
  K6 -- no --> K8
  K6 -- yes --> K7[Penalty charged from the carrier's balance, or kept DUE]
  K7 --> K8[Event trip.cancelled, credit notes for invoiced bookings]
  K8 --> K9([Trip CANCELLED, the decision kept])"""),
}
