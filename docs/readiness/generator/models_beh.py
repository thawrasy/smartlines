"""Behaviour models: state, sequence and activity diagrams in Mermaid, beyond ST-1 to ST-6 and SQ-1 to SQ-4 of models.py.

States follow the CHECK constraints of the tables and the functions that move them (the module named in each title);
activities follow the routes and checks of the code at commit b983b22."""

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
}
