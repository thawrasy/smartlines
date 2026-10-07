# Response to the third-party technical audit

The third-party technical audit reviewed the database design document v3.6 only, without the code or a built database.

**Its verdict:** conditional approval with a hardening plan, no rebuild. It recommended option A: harden within the
current modular monolith.

**How we checked it:** we compared every finding with a built database. The owner approved the database fixes and the
second phase of the audit. File `1046_audit_hardening.sql` (migration 1.28.0) carries the fixes; the tests are in
`db/tests/run_tests.sql` and `backend/tests/test_families.py`.

## Findings and their status

| Finding | Status | What the database shows, and what changed |
|---|---|---|
| R-01 RLS is not isolation by itself | In place; external test open | **Already true:** application roles own no table and have no superuser or BYPASSRLS. Every table has row-level security. No SECURITY DEFINER function runs with an open search path. The company context is set per transaction. **Tests:** pooled connections, COPY, per-company read isolation across every table, report exports, scheduled report runs and webhook scoping. **New (1047):** a write sweep tries to hand one of each company's rows to another company, in every table with a company column. It found three ways (files, documents through a typed column, sessions), and all three are closed and tested. **Open:** a penetration test by an external party. |
| R-02 Dependency cycles between modules | Confirmed, contained | 21 two-way schema dependencies exist, and test H-07 refuses any new one. That test caught one in our own route compliance work, which we then removed. At phase level no table requires a row of a later phase (tested). The design document now states both facts. |
| R-03 References without a foreign key | Fixed | Every (type, id) reference is registered in `sys.polymorphic_reference` (details below). A test fails on any unregistered pair. |
| R-04 Phone, e-mail and address protection | Fixed; the document contradicted the tables | Passenger and family-member phone numbers are now encrypted, persons' contact data has left the party, reporting and audit roles cannot read contact columns, and the change log masks them (details below). The document's claim "card and phone numbers hashed" is replaced by what is true: card numbers are never stored (only the last four digits; NFC card identifiers are hashed). |
| R-05 Many kinds of policy | Fixed | `sys.v_policy_matrix` lists every policy as table, data class, actor scope (tenant, owner, parent, platform, public, switch), command, and read and write conditions. A test requires the matrix to cover every policy, and no private table to accept writes unconditionally. The one designed exception, any transaction writing its own outbox events, is named in the test. The write sweep tests the WITH CHECK side of every company table. |
| R-06 A company as an extension of a party | Fixed | A company sits on a company or entity party. A person is allowed only for an individual owner-driver. A company's party cannot be turned into a person. |
| R-07 Double-entry balance | Already enforced | A deferred constraint trigger refuses an unbalanced or single-line transaction. An entry's wallet must match the transaction's currency. Each transaction can be reversed once, and a reversal cannot be reversed. Posted entries cannot change. The idempotency key is unique. Wallets are reconciled daily. |
| R-08 JSONB governance | Fixed | Every JSONB column (117) is registered in `sys.json_contract` with a kind and version. Rule and shape columns carry a contract (a subset of JSON Schema) the database checks on every write: fare rules, fee policy, compliance profile, crew seats, route shapes. Price and terms snapshots (booking price, ticket rules, refund policy, policy-change authority) are frozen once written. A test requires full registration and no stored value breaking its contract. |
| R-09 Tamper-proof logs | Fixed; archive needs its bucket | **Already true:** audit tables are append-only and sealed in a hash chain. **New:** every schema change is logged in `audit.ddl_event`, and a grant, policy, function, trigger or row-level security change made outside a migration raises `security.ddl_change`. `app.tools.audit_export` copies the logs out as chained, checksummed batches, with a `verify` command, for a bucket with object lock (`docs/operations/RUNBOOKS.md`, section 7). **Open:** the bucket itself. |
| R-10 Key management | Fixed; key service needs provisioning | Envelope encryption: data keys are stored wrapped in `sec.key_registry.wrapped_dek` and opened at start-up by the key service (`app/kms.py`: Vault Transit, or a local KEK for staging). `app.tools.keys` creates, wraps and checks keys, and `app.tools.rekey` rotates rows, moving sibling columns together. Rotation, break-glass and key checks after a restore are in the runbooks. **Open:** provisioning the Vault (or cloud KMS) service. |
| R-11 Data lifecycle matrix | Fixed | `gov.v_lifecycle_matrix` gives every inventoried dataset its data class, legal basis, retention, erasure method, copies (replicas, backups, object storage, outbox, webhooks, archive) and backup expiry. The daily upkeep purges delivered events, finished webhook deliveries and old notifications when their retention ends, and stops for a legal hold (tested). |
| R-12 Performance | Tools in place; staging run open | `loadtest.run` runs the booking spine at rising concurrency with p50, p95 and p99, and the one-seat race: 100 users, exactly 1 hold. `loadtest.rls_benchmark` measures what the policies cost on the hot queries. First measurements and their limits are in `docs/operations/PERFORMANCE_BASELINE.md`. **Open:** the run on staging with production-size data and hardware. |
| R-13 Table without a primary key | Closed | No table lacks a primary key; a test runs in CI. |
| R-14 Closed modules leaking | Fixed | Every table of a switched phase is now closed in the database, not only in the application (details below). |
| R-15 AI assistant boundaries | Deferred with its phase | The assistant moved to phase CS. The proposed guardrails are adopted for its design. |

### R-03: orphan sweep

- **Registry:** every (type, id) reference is listed with its targets, owner and reason. There are three kinds:
  - `TYPED`: backed by real foreign keys.
  - `BUSINESS`: the ledger, family spending, legal holds, channel and accounting mappings.
  - `METADATA`: audit logs, the outbox and journals, which outlive their rows on purpose.
- **Sweep:** `sys.find_orphans()` counts references to missing rows. The daily upkeep (`sys.run_maintenance`) runs it
  weekly, records the result in `sys.orphan_check`, and raises `integrity.orphans_found` through the outbox.

### R-04: contact data

- **Passengers and family members:** phone numbers are encrypted with the field key (`mobile_enc`, with `mobile_last4`
  for display). The clear columns must stay empty.
- **Persons:** contact lives only on their account. The migration moved what accounts lacked and cleared persons' party
  contact. Companies keep their business contact.
- **Reporting and audit roles:** they cannot read contact columns. The one exception is deliberate: the security console
  reads the account id and e-mail next to log rows, to show who acted.
- **Change log:** every contact field is masked.
- **Existing rows:** `python -m app.tools.seal_contacts --apply` seals clear values left in an older database, then
  prints the statements the owner runs to validate the constraints.

### R-14: phase gate

- **Switches:** each phase lists the switches that open it (`sys.project_phase.feature_keys`).
- **Gate:** every table of such a phase outside the module schemas gets a restrictive `phase_gate` policy
  (`sys.apply_phase_gates()`). With the switch off, a company reads and writes nothing of that phase; the platform still
  prepares it.
- **Phase map corrections it exposed:** the tracking positions and alerts used by the driver app and the regulator
  dashboard belong to release 1B, and the PostGIS reference table to 1A.

## What remains outside the repository

- A penetration test by an external party.
- Provisioning the key service, Vault Transit or a cloud KMS (R-10).
- The object-lock bucket for the audit archive (R-09).
- The load test on staging with production-size data (R-12).

The repository carries everything these need: the code, the tools, the tests and the runbooks
(`docs/operations/RUNBOOKS.md`). File `1047_audit_operations.sql` (migration 1.29.0) carries the database side of
R-01, R-05, R-08, R-09 and R-11.

## Owner decisions taken with these fixes

- **School transport** comes before the last phase (ordinal 15.5, before CS).
- **Electronic reporting of violations** waits for the government's e-government infrastructure, expected beyond two
  years. It moves to Phase 5, government integration, and requirement `route.report.authority` stays OFF.

## Second phase of the audit

The owner approved the second phase. `db/tools/audit_pack.sh <database> <dir>` builds the evidence the auditors asked
for from a built database and the running API. It contains:

- the schema without data;
- roles and their attributes, table grants and hidden columns;
- every policy;
- the security inventory;
- SECURITY DEFINER functions with their settings;
- triggers and foreign keys;
- the polymorphic reference registry and current orphan findings;
- schema dependencies;
- the phase map with its switches;
- configurable requirements;
- the JSONB inventory;
- tables without a primary key (none);
- extensions;
- the server version;
- the OpenAPI document.

Each file has a SHA-256 checksum. No business rows or key material are exported. Together with the repository (schema
files 000 to 1046, API code, workers and tests), this is what the auditors listed in section 10 of their report.
Items that do not exist yet are their own pre-launch work, not part of the pack: the backup and DR plan, the KMS, and a
staging environment.
