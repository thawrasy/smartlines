"""Addendum to the use case and data flow model of v1.0 (docs/diagrams/uc-dfd): what the platform gained after study
v2.5, taken from the code and the schema (migrations 1056 to 1099). Numbering continues v1.0: UC-11.., P15.., D18.."""

NEW_ACTORS = [
    ("stationop", "Station operating company staff", "Primary",
     "Staff of a company that runs station counters for carriers; signs in to its own STATION portal", "1098, 1099"),
    ("privacy", "Privacy officers", "Primary",
     "Platform staff holding privacy.manage; one proposes, others approve in the configured stages", "1087-1096"),
    ("counter", "Carrier counter agent", "Primary",
     "Carrier staff who sell tickets for cash and take pay-later payments at the counter", "1056"),
    ("boardstaff", "Driver, carrier office or agent", "Primary",
     "Staff who see a passenger's photo at boarding, each only if the platform's view setting allows it", "1096"),
    ("idprov", "Identity provider", "Secondary (system)",
     "Service that checks a person against an official identity source; none is connected yet", "1096"),
    ("stationsys", "Station's own counter system", "Secondary (system)",
     "A station that runs its own counter system, to be linked to the platform", "1097"),
    ("screens", "Station screens", "Secondary (device)", "Departure and gate boards fed by the platform", "1013, 1097"),
]

NEW_UC = [
    dict(id="UC-11", title="Boarding stations and operating companies", boundary="Masslak: boarding stations",
         primary=["admin", "owner", "stationop"], secondary=["stationsys", "screens"],
         cases=[("11.1", "Set the boarding settings", 1), ("11.2", "Switch a station on and choose its counter system", 1),
                ("11.3", "Open counters and bays numbered by the platform", 1), ("11.4", "Onboard an operating company", 1),
                ("11.5", "Grant a state-mandated operator its rights", 1), ("11.6", "Record agreement and licence numbers", 1),
                ("11.7", "Retire a reference number", 1), ("11.8", "Grant an operating company rights at a station", 1),
                ("11.9", "Revoke a grant", 1), ("11.10", "Sign in to the station portal with a second factor", 1),
                ("11.11", "View the rights held and the counters", 1), ("11.12", "Check in and issue the boarding pass (planned)", 1),
                ("11.13", "Decide whether the operator may act", 1), ("11.14", "Show the bay on the station screens (planned)", 1)],
         assoc=[("admin", "11.1"), ("admin", "11.2"), ("admin", "11.3"), ("admin", "11.4"), ("admin", "11.5"), ("admin", "11.9"),
                ("owner", "11.6"), ("owner", "11.7"), ("owner", "11.8"), ("owner", "11.9"),
                ("stationop", "11.10"), ("stationop", "11.11"), ("stationop", "11.12"),
                ("11.2", "stationsys"), ("11.14", "screens")],
         include=[("11.11", "11.13"), ("11.12", "11.13")], extend=[]),
    dict(id="UC-12", title="Boarding photo and its policy", boundary="Masslak: boarding photo",
         primary=["passenger", "privacy", "boardstaff"], secondary=["idprov"],
         cases=[("12.1", "Take the own photo or a family member's", 1), ("12.2", "See the own photo", 1),
                ("12.3", "Request a photo change with evidence", 1), ("12.4", "Apply or reject a photo change", 1),
                ("12.5", "Propose a photo rule", 1), ("12.6", "Approve or retire a photo rule", 1),
                ("12.7", "Switch the photo feature, with its legal basis", 1), ("12.8", "Change a photo setting", 1),
                ("12.9", "Approve a policy change in its stages", 1), ("12.10", "Set the approval stages", 1),
                ("12.11", "See the passenger's photo at boarding", 1), ("12.12", "Check the view setting and the boarding status", 1),
                ("12.13", "Verify identity with a provider (planned)", 1)],
         assoc=[("passenger", "12.1"), ("passenger", "12.2"), ("passenger", "12.13"),
                ("privacy", "12.3"), ("privacy", "12.4"), ("privacy", "12.5"), ("privacy", "12.6"), ("privacy", "12.7"),
                ("privacy", "12.8"), ("privacy", "12.9"), ("privacy", "12.10"), ("boardstaff", "12.11"), ("12.13", "idprov")],
         include=[("12.7", "12.9"), ("12.8", "12.9"), ("12.11", "12.12")], extend=[]),
    dict(id="UC-13", title="Payment options", boundary="Masslak: paying for a booking",
         primary=["admin", "finance", "passenger", "counter", "agency"], secondary=["gateway"],
         cases=[("13.1", "Open or close a payment option, with a reason", 1), ("13.2", "Set an option's channels, limits and settings", 1),
                ("13.3", "Pay at once from the wallet", 1), ("13.4", "Reserve now, pay later at the counter", 1),
                ("13.5", "Take cash at the counter: sale or pay-later", 1), ("13.6", "Sell from the agency balance", 1),
                ("13.7", "Pay by card, instalments or financing (when a provider is active)", 1),
                ("13.8", "Check the option is open and the amount within its limits", 1)],
         assoc=[("admin", "13.1"), ("admin", "13.2"), ("finance", "13.1"), ("finance", "13.2"), ("passenger", "13.3"),
                ("passenger", "13.4"), ("passenger", "13.7"), ("counter", "13.5"), ("agency", "13.6"), ("13.7", "gateway")],
         include=[("13.3", "13.8"), ("13.4", "13.8"), ("13.5", "13.8"), ("13.6", "13.8"), ("13.7", "13.8")], extend=[]),
]

NEW_PROCESSES = [("15", "Operate boarding stations"), ("16", "Manage boarding photos")]

NEW_STORES = [
    ("D18", "Boarding settings and stations", "sys.setting boarding.*, net.station_boarding, net.station_gate (counters and bays)",
     "Off at launch; numbers never reused"),
    ("D19", "Operator grants", "net.station_operator_grant", "Revoked, never changed or deleted; each party sees its own"),
    ("D20", "Operation references", "net.operation_reference", "Retired, never changed; isolated per carrier"),
    ("D21", "Boarding photos", "iam.party_photo, encrypted files in object storage", "Encrypted; shown only by setting and trip status"),
    ("D22", "Photo policy", "photo_rule, photo_policy_change, photo approvals, evidence kinds, data requirements, photo.* settings",
     "Every change passes the approval stages"),
]

DFD15 = ("DFD-15", "DFD-15 Level 2: operate boarding stations (P15)", dict(
    externals=[("admin", "Platform administrator"), ("carrier", "Carrier (operations)"), ("op", "Station operating company staff")],
    procs=[("s1", "15.1", "Set the boarding settings"), ("s2", "15.2", "Switch stations and number counters and bays"),
           ("s3", "15.3", "Onboard operating companies"), ("s4", "15.4", "Keep reference numbers"),
           ("s5", "15.5", "Grant and revoke operator rights"), ("s6", "15.6", "Decide and show the operator's rights")],
    refs=[("p1", "P1")],
    stores=[("d18", "D18"), ("d2", "D2"), ("d1", "D1"), ("d20", "D20"), ("d19", "D19"), ("d16", "D16")],
    flows=[("admin", "s1", "switch, modes, check-in window, required references"), ("s1", "d18", "checked settings"),
           ("admin", "s2", "station switch, counter system, gate type"), ("s2", "d18", "station boarding row, numbered gate"),
           ("s2", "admin", "gate number (C001, B001)", {"constraint": False}),
           ("admin", "s3", "company and owner"), ("s3", "d2", "company of type STATION_OPERATOR"),
           ("s3", "d1", "owner account and membership"),
           ("carrier", "s4", "agreement and licence numbers, retirements"), ("s4", "d20", "reference rows"),
           ("d18", "s4", "required references"), ("s4", "carrier", "missing references", {"constraint": False}),
           ("carrier", "s5", "grant or revoke: operator, station, right"), ("admin", "s5", "state-mandated grant"),
           ("s5", "d19", "grant, revocation"), ("s5", "d16", "who granted, when"),
           ("op", "p1", "sign-in, second factor"), ("p1", "s6", "STATION session"),
           ("d19", "s6", "grants given to the company"), ("d18", "s6", "switches, modes, counters"),
           ("s6", "op", "rights usable now, counters", {"constraint": False})]))

DFD16 = ("DFD-16", "DFD-16 Level 2: manage boarding photos (P16)", dict(
    externals=[("pax", "Passenger or head of family"), ("priv", "Privacy officers"), ("staff", "Driver, carrier office or agent"),
               ("idp", "Identity provider (not connected)")],
    procs=[("h1", "16.1", "Take and keep photos"), ("h2", "16.2", "Manage photo rules"),
           ("h3", "16.3", "Change policy and settings in stages"), ("h4", "16.4", "Change a photo on file (two people)"),
           ("h5", "16.5", "Show a photo"), ("h6", "16.6", "Verify identity")],
    refs=[("p4", "P4")],
    stores=[("d21", "D21"), ("d22", "D22"), ("d5", "D5"), ("d16", "D16")],
    flows=[("pax", "h1", "photo of self or a family member"), ("h1", "d21", "encrypted photo"),
           ("d22", "h1", "feature switch"), ("priv", "h2", "rule: market, category, requirement, legal basis"),
           ("h2", "d22", "rule and its approvals"),
           ("priv", "h3", "switch with legal basis, setting value, document number, approvals"), ("h3", "d22", "applied change"),
           ("priv", "h4", "change request with evidence, decision"), ("h4", "d21", "replaced photo"),
           ("pax", "h5", "own photo request"), ("staff", "h5", "ticket at boarding"), ("d22", "h5", "view setting"),
           ("d5", "h5", "trip status BOARDING"), ("d21", "h5", "photo"),
           ("h5", "pax", "own photo", {"constraint": False}), ("h5", "staff", "passenger's photo", {"constraint": False}),
           ("h5", "d16", "who saw which photo"), ("pax", "h6", "verification request"),
           ("h6", "pax", "refused until a provider is connected", {"constraint": False}),
           ("h6", "idp", "verification (when connected)"), ("d22", "p4", "photo rules, enforcement date")]))

STATES = {
    "ST-1": ("Booking", """stateDiagram-v2
  direction LR
  [*] --> PENDING_PAYMENT: reservation (pay later, card, instalments, financing)
  [*] --> CONFIRMED: paid at once (wallet, agency balance, counter cash)
  PENDING_PAYMENT --> CONFIRMED: payment succeeds before the pay-by time
  PENDING_PAYMENT --> EXPIRED: pay-by time passes
  PENDING_PAYMENT --> CANCELLED: cancelled
  CONFIRMED --> CANCELLED: cancelled and refunded by the fare brand
  CONFIRMED --> COMPLETED: trip completed
  EXPIRED --> [*]
  CANCELLED --> [*]
  COMPLETED --> [*]"""),
    "ST-2": ("Ticket", """stateDiagram-v2
  direction LR
  [*] --> ISSUED
  [*] --> HOLD: reservation not yet paid
  HOLD --> ISSUED: paid
  HOLD --> CANCELLED: not paid in time, or cancelled
  ISSUED --> BOARDED: boarding scan at its stop
  ISSUED --> NO_SHOW: trip left without the passenger
  ISSUED --> HOLD: back to hold (allowed by the database rule)
  ISSUED --> CANCELLED: cancelled
  BOARDED --> [*]
  NO_SHOW --> [*]
  CANCELLED --> [*]"""),
    "ST-3": ("Payment", """stateDiagram-v2
  direction LR
  [*] --> PENDING
  PENDING --> SUCCESS: signed notification and a ledger entry
  PENDING --> FAILED: refused, expired or cancelled
  FAILED --> SUCCESS: late provider payment after an expired hold
  SUCCESS --> REFUNDED: refund
  REFUNDED --> [*]"""),
    "ST-4": ("Trip", """stateDiagram-v2
  direction LR
  [*] --> DRAFT
  DRAFT --> PUBLISHED: published by the carrier
  PUBLISHED --> BOARDING: boarding opens
  BOARDING --> DEPARTED: departure
  DEPARTED --> COMPLETED: arrival
  PUBLISHED --> CANCELLED: cancelled
  BOARDING --> CANCELLED: cancelled
  COMPLETED --> [*]
  CANCELLED --> [*]"""),
    "ST-5a": ("Photo policy change", """stateDiagram-v2
  direction LR
  [*] --> PENDING: asked by one officer (stages copied)
  PENDING --> PENDING: one stage approved by another person
  PENDING --> APPLIED: last stage approved
  PENDING --> REJECTED: rejected
  APPLIED --> [*]
  REJECTED --> [*]"""),
    "ST-5b": ("Photo rule", """stateDiagram-v2
  direction LR
  [*] --> PROPOSED: proposed with its legal basis
  PROPOSED --> APPROVED: last stage approved
  PROPOSED --> RETIRED: withdrawn before it is in force
  APPROVED --> RETIRING: retirement asked
  RETIRING --> APPROVED: retirement rejected
  RETIRING --> RETIRED: retirement approved by another person
  RETIRED --> [*]"""),
    "ST-6a": ("Operator grant", """stateDiagram-v2
  direction LR
  [*] --> ACTIVE: granted by the carrier or the platform
  ACTIVE --> REVOKED: revoked by the party that gave it
  REVOKED --> [*]"""),
    "ST-6b": ("Operation reference", """stateDiagram-v2
  direction LR
  [*] --> ACTIVE: recorded by the carrier
  ACTIVE --> RETIRED: retired, corrected by a new row
  RETIRED --> [*]"""),
}

SEQUENCES = {
    "SQ-1": ("Booking, paid at once or reserved", """sequenceDiagram
  autonumber
  actor P as Passenger
  participant A as Passenger app or website
  participant S as API
  participant D as Database
  participant G as Payment provider
  P->>A: chooses trip, seats and passengers
  A->>S: POST /api/holds
  S->>D: lock the seat segments
  S-->>A: hold token
  A->>S: POST /api/bookings (hold token, passengers, pay_with)
  S->>D: rules: photo required? option open? amount in limits?
  alt pay_with WALLET
    S->>D: booking CONFIRMED, tickets ISSUED, ledger entry
    S-->>A: CONFIRMED
  else PAY_LATER, CARD, INSTALLMENT or FINANCING
    S->>D: booking PENDING_PAYMENT, pay-by time
    S-->>A: PENDING_PAYMENT, pay_by
    A->>S: POST /api/bookings/{ref}/payments (provider)
    S->>G: payment request
    G-->>S: signed notification
    S->>D: payment SUCCESS, booking CONFIRMED
  end
  A->>S: GET /api/tickets/{uid}/qr
  S-->>A: signed rotating QR"""),
    "SQ-2": ("Boarding scan by the driver", """sequenceDiagram
  autonumber
  actor R as Driver
  participant M as Driver app
  participant S as API
  participant D as Database
  R->>M: scans the passenger's QR
  M->>S: POST /api/driver/scan (token, trip, stop)
  S->>S: check the QR signature and its time
  S->>D: trip assigned to this driver?
  S->>D: ticket valid for this trip and this stop?
  alt valid
    S->>D: boarding event OK, ticket BOARDED
    S-->>M: boarded
  else wrong stop, duplicate or invalid
    S->>D: boarding event with its refusal reason
    S-->>M: refused, with the reason
  end
  Note over M,S: Without a connection the app keeps scans and sends them with POST /api/driver/scans/batch"""),
    "SQ-3": ("Photo setting change in stages", """sequenceDiagram
  autonumber
  actor A as Officer A
  actor B as Officer B
  actor C as Officer C
  participant S as API
  participant D as Database
  A->>S: POST /api/admin/photos/settings/changes (key, value, reason)
  S->>D: check the value, change PENDING with a copy of the stages
  B->>S: POST /api/admin/photos/policy-changes/{uid}/approve (document number optional)
  S->>D: stage CHECK recorded (not by the one who asked)
  S-->>B: PENDING
  C->>S: POST .../approve
  S->>D: stage APPROVE recorded, setting applied, change APPLIED
  S-->>C: APPLIED"""),
    "SQ-4": ("Operating company rights at a station", """sequenceDiagram
  autonumber
  actor K as Carrier
  actor O as Operating company staff
  participant S as API
  participant D as Database
  K->>S: POST /api/carrier/station-operators/grants (operator, station, right)
  S->>D: grant (written only by this carrier)
  O->>S: POST /api/auth/login (portal STATION) and second factor
  S->>D: company of type STATION_OPERATOR?
  O->>S: GET /api/station/overview
  S->>D: grants given to this company, net.operator_may(...)
  S-->>O: rights usable now, counters
  K->>S: POST .../grants/{uid}/revoke
  S->>D: revoked (never deleted)"""),
}
