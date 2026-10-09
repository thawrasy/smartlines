# External technical report of October 2026: assessment and actions

The owner received a "comprehensive technical, operational and engineering analysis" of Masslak v1.45.0 from a third
party (October 2026; the document names an infrastructure and information systems project office, without a company,
authors or signature). Every claim about the system was checked on 9 October 2026 against a database built from release
1.45.0 (79 schema files), the code at commit 9724805, the tests and the evidence files. The Arabic assessment given to the
owner has the same content.

**Summary.** The report gives no evidence from the system (no file, table, query plan, test result or installation log),
and its examples name columns the schema does not have (`waybill_number`, a `version` column on the seat table). Of its
nine claims about the system, six are contradicted by the system, two are partly right and one does not apply. Two
points lead to work: cargo capacity (schema file 1067) and disk encryption at rest (hosting requirements).

## Claims about the system

| # | Claim | Finding | Evidence |
|---|---|---|---|
| 1 | Referential integrity is left to the application, so orphan rows appear | Contradicted | 1,402 foreign keys over 488 tables, every one indexed; 1,408 CHECK and 26 exclusion constraints; `sys.find_orphans()` returns 0 and runs weekly in maintenance; the application role deletes from 36 listed tables only (1059) |
| 2 | No composite indexes for seat and shipment queries | Contradicted | 321 composite indexes, among them `seat_segment_avail (trip_id, seg) WHERE status = 'AVAILABLE'`, `trip_search_idx (route_id, departure_at)`, `ticket_trip_idx (trip_id, status)`; tracking numbers unique; `handling_unit.current_station_id` indexed |
| 3 | Seats are double-booked through a non-atomic check-then-act | Contradicted | one row per seat and segment, keyed `(trip_id, seat_no, seg)`, locked with `SELECT ... FOR UPDATE` in a fixed order and updated in one statement; `test_seat_contention_one_seat_one_winner` (20 concurrent requests, one winner); 0 seats sold twice in every burst, 779 refused attempts on taken seats in the run of 9 October |
| 4 | READ COMMITTED without locking allows dirty reads | Contradicted | PostgreSQL never reads uncommitted data at any isolation level; `FOR UPDATE` is used in 38 places in the API and 15 in database functions; the ledger balance is checked at commit |
| 5 | Offline POS devices sync without ordering and conflict | Does not apply | nothing is sold offline, by design; offline boarding checks Ed25519-signed tickets from a pack downloaded before departure, scans are uploaded later with their own ids and the server decides; positions carry an event id, a counter and the device time, duplicates are dropped |
| 6 | Seat holds never expire | Contradicted | every lock has `lock_expires_at`; an expired lock counts as free in every query and `ops.release_expired_holds()` clears it in maintenance; pay-later reservations have a pay-by time |
| 7 | Nothing stops parcels from exceeding a bus's legal load | **Partly right** | the capacity tables had a maximum and a CHECK on the used weight, but nothing updated the used weight and the maximum was not tied to the vehicle. Shipping is phase 3 and its schema is closed while the `cargo` switch is off. Fixed by 1067, below |
| 8 | Commissions are batch-computed at the end of the day; no real-time double-entry ledger | Contradicted | double-entry ledger balanced at commit, append-only (trigger and revoked privileges), reversals mirror their original; an agent's commission is a leaf of the booking's price allocation, posted with the sale, held in escrow and released on its event; `test_concurrent_wallet_bookings_stay_balanced` |
| 9 | Weak security and access control; TDE, OAuth2/JWT and RBAC recommended | **Partly right** | row-level security on 488 of 488 tables (910 policies), permission matrix, second factor for staff, AES-256-GCM for identity numbers, documents and second-factor secrets, encrypted backups, signed audit chain, partner keys with scopes and address lists. JWT is not safer than the server sessions used. PostgreSQL has no TDE and the hosting requirements did not ask for encrypted disks: added, below |

## Recommendations

| Recommendation | Position |
|---|---|
| Partitioning bookings and shipments | Done: bookings (1064), ledger entries by month (1052), positions by day in their own database (1063) |
| Immutable ledger, event sourcing | Done: append-only ledger, outbox events, signed audit hash chain exported to a write-once archive |
| Read replicas | Done: reports read the streaming replica, checked by the installation job in CI |
| OLTP and OLAP separated, archiving | Done: warehouse fed by change data capture without personal data (D3), retention and purge per table (1047) |
| Disaster recovery and high availability | Done: Patroni with a synchronous standby, a second site, pgBackRest with two repositories (D6); the staging run is launch gate 1 |
| Access control and API protection | Done (claim 9); OAuth2 client credentials for partners can be added when a bank asks |
| Load test to 50,000 transactions a minute | Agreed and planned as launch gate 3, with targets from the capacity model (240, 480 and 1,200 bookings a second, an 8-hour soak) |
| Penetration test, SOC 2 | Penetration test agreed: launch gate 8, external firm, written scope. SOC 2 is not a legal requirement here; considered if a partner asks |
| Redis Redlock and a version column on seats | Rejected: a second source of truth for seats; Redlock is unsafe without fencing tokens; the database lock is correct and tested. Redis may later cache search results |
| CRDTs for offline sync | Rejected: a CRDT merges conflicting writes, so two offline sales of one seat would both stand |
| Microservices and geographic sharding for sub-10 ms latency | Rejected for now: booking, payment and commission are one transaction; modules are separate inside one database and CI blocks new two-way dependencies; the sharding study (D4) splits by market first; simple database operations already take about 1 ms |

## Actions taken

| Action | Where |
|---|---|
| Cargo within the vehicle's capacity: used weight, volume and pieces computed from what is placed (segment by segment on a trip), overloads refused, maximums tied to the vehicle's registered capacity, concurrent loading serialised | `db/schema/1067_cargo_capacity.sql`; 13 database checks; `backend/tests/test_cargo_capacity.py`; rule `CARGO-WITHIN-CAPACITY` in `docs/database/invariants.json` |
| Disks and volumes encrypted at rest for every stage, object storage with server-side encryption | `INFRASTRUCTURE_REQUIREMENTS.md` sections 5 and 13, `STAGING.md`, `deploy/README.md` |
