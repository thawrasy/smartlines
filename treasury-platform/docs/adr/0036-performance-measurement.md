# ADR 0036: Measuring the performance of the database on synthetic data

Status: decided by the database architect on the owner's request of 2026-10-21 to build item 1 of the study of review
v5.0 (docs/39 section 8; the review's P0-2). Results and findings in docs/40; the raw run in docs/perf/perf-run.txt and
the generated report in docs/perf/perf-results.md.

## Context

NFR-SCL-01 and NFR-SCL-02 set 300 tenants and 50,000 records a main table a tenant (DQ-B03-4); NFR-PERF-01 asks 2
seconds a screen at that volume and NFR-PERF-06 20 ms for the session binding. Nothing had been measured. The service
layer is not built, so only the paths the database itself implements can be measured now: the binding, what screens
read, the writes with their triggers and the audit chain, the credit computation, the evidence pack, the jobs, and the
deployment.

## Decision

1. **Synthetic data through the real schema** (`tools/perf/perf_seed.sql`). Every row goes through the tables, keys,
   checks, row filters and triggers of the application's data, written as a user bound to its tenant; nothing is
   switched off. Roles come from the pack CORE.ROLES. By default 300 tenants:
   - three *full* tenants at the volume of NFR-SCL-02 on the tables those paths read: 200 companies; 5 approved years
     of statements of 55 lines each (55,000 lines); a facility each with its lender, limit, use, revision and covenant;
     57 confirmed monthly bank flows each; a computed and approved credit assessment each, 20 of them endorsed by the
     risk officer; 50,000 audit rows (each one chained by the trigger) and 50,000 past sessions;
   - 297 *light* tenants with a company, a statement, 2,000 audit rows and 500 sessions, so that the shared tables hold
     300 tenants around the measured one.
   Not every tenant is full size. That would be about 20 million rows on these tables alone, which the container of
   this run (4 processors, 15 GB, 18 GB of disk) cannot hold in reasonable time. Every index leads with TenantId, and
   every row filter narrows to one tenant, so a tenant's reads depend on its own rows. The neighbours add the depth of
   the shared indexes. Running the same tool at full size is for the test environment of DQ-B03-9.
2. **The measurement** (`tools/perf/perf_measure.sql`, `tools/perf/run_perf.sh`):
   - It runs on a fresh database deployed through the production path.
   - Each scenario reports p50, p95 and max of server-side samples. A fast read is repeated 20 times in a sample,
     because the server clock moves in steps of about 4 ms.
   - The binding of NFR-PERF-06 uses a new connection for each call, since its keys are read-only for the life of a
     connection.
   - Four writers append to one tenant's audit chain at once, and the chain is verified afterwards.
   - The repeatable scripts of `migrate.sh` run on the loaded database, which gives the length of a deployment window.
   - The run also records the table sizes, the costliest statements and the indexes the optimiser asks for.
   - `perf_report.py` writes the report from the raw lines, so no number is typed by hand.
3. **Targets.**
   - Binding: 20 ms (NFR-PERF-06).
   - What a screen reads: 200 ms at p95. This is a tenth of the 2 seconds of NFR-PERF-01, a proposal recorded as
     DQ-B03-11.
   - The heavier screens (the tenant's early warnings, the breach report): the whole 2 seconds.
   - The jobs and the deployment window have no target in DOC-B03 and are reported only.
4. **What the measurement changed.**
   - A full check of a tenant's audit chain grows with the log: about 40 microseconds a row. The daily check now runs
     from the latest anchor, and a weekly full check covers the old rows (ADR 0033, tests AC7 and AA3).
   - The chain's filter now seeks on its index. In the first form, one statement with ISNULL or an OR, it read the
     tenant's whole range. Each read is now two guarded statements, one for a tenant's chain and one for the
     platform's. Logical reads went from 2,422 to 176, and J4 from 0.25 to 0.17 s. These two numbers come from a probe
     after the committed run, not from `perf-run.txt`; the next run of the tool shows them.
   - No index was added. The requests that came from the measurement's own lookups were set aside. The one that applies
     to the system (fin.BankFlowEntry by tenant, 21% impact) is proposed in docs/40, under the owner's decision D-6.
5. **In CI** (step 24) the same scripts run at small sizes, so a change of the schema cannot break them unseen.

## What stays open

- The full volume (300 full tenants), on the resources of production (DQ-B03-9).
- NFR-PERF-01 end to end, NFR-PERF-03 (concurrent reservations) and NFR-PERF-05 (login with Argon2id). These are paths
  of the service layer and are measured with it.
- READ_COMMITTED_SNAPSHOT, a recommendation of docs/20, was not switched on: the run measures the default isolation.
