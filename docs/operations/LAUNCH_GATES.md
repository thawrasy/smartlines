# Launch gates (go/no-go register)

This register follows section 6 of the auditors' follow-up report on design v3.9 (8 October 2026): nine gates. General
launch needs every gate except AI/CS to be **Passed**. The AI/CS gate applies only before that phase's switch opens.
While its switch stays closed, the AI/CS phase does not hold back the core launch.

**How a gate is passed:**
1. The responsible party runs the work.
2. The result goes as a file into `docs/operations/evidence/`, or into the external firm's signed report.
3. The approver signs the row below with the date.
4. A gate is passed only when its evidence file exists and its success criterion is met in that file. A development
   measurement is never enough.
5. A failed run is recorded too, with its fix, and the gate is run again.

**Owner decisions this register relies on (8 October 2026):**
- **Recovery targets:** RPO 60 s and RTO 30 min are approved. They are stored as `recovery.rpo_seconds` and
  `recovery.rto_minutes`.
- **SLOs:** approved (`SLO.md`) and stored as `slo.objectives`.
- **Who runs staging and the penetration test:** external cybersecurity firms or independent testers.
- **Reviewer access:** through the permission matrix only (`sec.external_access_grant`): time-bound, granted by a second
  person, never by default and never open-ended.

**Status values:** Open, In progress, Passed, Failed (re-run due), Not applicable yet.

## Register

| # | Gate (audit refs) | Work required before the decision | Success criterion | Measured by | Evidence | Responsible / approver | Status, date |
|---|---|---|---|---|---|---|---|
| 1 | **Recovery** (R-01, T3-01) | Owner approves RPO and RTO (done 8 Oct 2026). pgBackRest full backup plus point-in-time restore, on staging with 1x data, to a new host | Restore repeatable within RPO 60 s and RTO 30 min; wallets reconcile, ledger balances, no orphans, audit seals verify, schema hash equal | `pgbackrest restore`, then the checks of `db/tools/restore_drill.py`; timed from the declared loss | `evidence/restore_staging_<date>.json`, operator's run log | Staging firm / platform owner + DBA | Open (development drill passed 7 Oct 2026: 3.2 s lost, 4.9 s to usable) |
| 2 | **Egress** (R-02, T3-02) | Egress proxy running in production with the real allowlist of providers and partners | No direct route out of the API or worker containers; forbidden destinations refused; network test passes | `deploy/egress/selftest.sh` inside the production network; a direct-connection attempt from the API container; review of the allowlist | `evidence/egress_production_<date>.txt`, allowlist as deployed | Operations / security lead | Open (repository part closed; CI runs the self-test) |
| 3 | **Capacity** (R-09, T3-09) | Staging with representative data at 1x, 2x and 5x the expected peak (`db/tools/generate_volume.py`) | SLOs hold at 1x and 2x with no 5xx beyond budget, no money mismatch, no unhandled deadlocks, no trigger over 1 ms per row, reports served from the replica; at 5x the limit and first saturated resource recorded | `backend/loadtest/run.py --mix full --owner-dsn ...` per scale | `evidence/load_1x_<date>.json`, `load_2x_…`, `load_5x_…` | Staging firm / platform owner | Open (development: 10–50 users, 0 errors) |
| 4 | **Migrations** (R-08, T3-08) | Rehearsal of each release on a production-size copy | Locks, WAL and time within the limits of `docs/database/MIGRATION_PLANS.md`; forward-fix plan written | `db/tools/migration_rehearsal.py --base <previous release>` | `evidence/migration_rehearsal_<release>_<date>.json` | DBA / release manager | Open (development: 1048 rehearsed, finding documented) |
| 5 | **Monitoring** (R-16, T3-16) | Prometheus, Alertmanager and Grafana deployed (`deploy/staging`, then production); SLOs approved (done); on-call rota; alert drill | A test alert reaches the on-call engineer and is handled by the named runbook; time to acknowledge ≤ 15 min recorded | Alert drill (`SLO.md`, On call) | `evidence/alert_drill_<date>.md` | Operations lead / platform owner | Open (rules, tests, dashboard in the repository) |
| 6 | **Audit archive** (R-13, T3-13) | Bucket with object lock in a separate account; custodian records the chain tip | Export succeeds; signature and chain verify; a past export can be retrieved and verified | `python -m app.tools.audit_export` (export, then verify), retrieval test | `evidence/audit_archive_<date>.txt`, custodian's signed receipt of the tip | Security lead / custodian | Open |
| 7 | **File scanning** (R-15, T3-15) | ClamAV next to the API with signature updates; backlog monitored | Fails closed when the scanner is down; no file other than CLEAN is ever served | Upload clean, EICAR and with the scanner stopped; `FilesWaitingForScan` alert | `evidence/file_scanning_<date>.txt` | Staging firm / security lead | Open (EICAR detected through ClamAV in the kit check, 7 Oct 2026) |
| 8 | **Security testing** | Independent external penetration test (`docs/security/PENETRATION_TEST_SCOPE.md`) and remediation | Every critical or high finding fixed and retested, or formally accepted by the owner with a dated reason | The firm's report and retest report | Firm's signed report and retest letter, remediation register | External firm / owner | Open |
| 9 | **AI and contact centre** (R-20, T3-20) | Threat model, DPIA and acceptance criteria approved before the phase switch opens | The phase switch cannot open without the approvals and tests | `docs/architecture/AI_ASSISTANT_THREAT_MODEL_DPIA.md` sign-off; phase-gate test | Signed DPIA, test log | Data protection officer / owner | Not applicable yet (phase switched off) |

## Decision

| Item | Record |
|---|---|
| Gates 1–8 passed | (date, approver) |
| Open risks accepted by the owner | (list with reasons and dates; critical or high findings cannot be accepted without a written reason) |
| Go / no-go for general launch | (decision, date, signatures: platform owner, security lead, operations lead) |
| Re-issue of the auditors' readiness verdict | Requested after gates 1–8 (the report's final recommendation) |
