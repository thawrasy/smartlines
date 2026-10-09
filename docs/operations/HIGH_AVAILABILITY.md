# Automatic failover and the second site

Expert review of October 2026, stage D6. Configuration in `deploy/ha/`, schema file `1065_failover.sql`, drill tool
`db/tools/failover_drill.py`, operations in `docs/operations/RUNBOOKS.md` sections 3 and 23.

## Targets

| Event | Data lost (RPO) | Back to taking bookings (RTO) | Who decides |
|---|---|---|---|
| The primary server fails | none: a synchronous standby confirmed every commit | 60 s: Patroni's detection (about 30 s) and the clients' reconnection | Patroni, automatically |
| The main site is lost | the WAL not yet streamed or archived to the second site: seconds, at most 60 s | 30 minutes (the approved RTO): the decision, the promotion, pointing the applications at the second site | the on-call lead, by the runbook |
| Data is damaged (a bad migration, a deleted table) | back to any second in the last 7 days | 30 minutes on new hardware | the DBA, by RUNBOOKS.md section 2 |

The 60-second RPO and 30-minute RTO are the owner's approved targets (8 October 2026); the one-minute failover is
the target of RUNBOOKS.md section 3.

## Layout

```
                main site                                              second site
  ┌───────────────────────────────────────────┐            ┌───────────────────────────────────┐
  │ etcd ×3 (one on a witness host)            │            │ etcd ×3 (its own vote)             │
  │ db-a1 ── synchronous streaming ── db-a2    │  async     │ db-b1: Patroni standby cluster     │
  │   Patroni        (primary ↔ standby)       │ ─────────▶ │   streams from HAProxy :5000,       │
  │ HAProxy :5000 → primary, :5001 → standby   │ streaming  │   falls back to WAL in repo2        │
  │ PgBouncer → HAProxy :5000                  │            │ API, worker, Caddy: built, stopped  │
  │ API, worker, Caddy                         │            │                                     │
  └───────────────────────────────────────────┘            └───────────────────────────────────┘
        │ archive-push (every segment, both repositories)
        ▼
  repo1: object storage, main region                  repo2: object storage, second site's region
```

- **Patroni** (`deploy/ha/patroni.yml`) holds the leader key in etcd. When the primary stops renewing it (ttl 30 s),
  the standby that is synchronous and caught up is promoted. `synchronous_mode` makes one standby confirm every
  commit, so the promoted server has every booking and payment the clients were told about. If the standby is
  down, Patroni drops to asynchronous rather than stopping bookings; `NoSynchronousStandby` and
  `NoFailoverCandidate` alert. `use_pg_rewind` lets the old primary rejoin as a standby without a full copy.
- **Logical replication slots** (the warehouse, `masslak_dw`) are declared in Patroni's configuration, so they exist
  on the standby too and the warehouse keeps streaming after a failover.
- **HAProxy** (`deploy/ha/haproxy.cfg`) asks each server's Patroni API whether it is the primary (`/primary`) or a
  healthy standby (`/replica?lag=30s`). It marks a server down within 3 s and cuts its sessions, so clients reconnect
  to the new primary. PgBouncer and the audit connection go to port 5000, reports to port 5001.
- **The applications** may also list the servers themselves, without HAProxy: `MASSLAK_DATABASE_URL=
  postgresql://user:pw@db-a1:5432,db-a2:5432/masslak?target_session_attrs=read-write` connects to whichever is the
  primary. During a failover the API answers 503 with `Retry-After: 2` (`SERVICE_BUSY`) instead of an error page, and
  `/api/ready` reports not ready until the pool reaches a primary again (a standby does not count). Bookings and
  payments carry idempotency keys, so a client's retry never doubles them.
- **pgBackRest** (`deploy/ha/pgbackrest.conf`) archives every WAL segment to two repositories, one per site, and
  takes backups from a standby. A segment is closed at least every 60 s (`archive_timeout`).
- **The second site** runs a Patroni standby cluster (`deploy/ha/patroni-site-b.yml`) that streams from the main
  site and falls back to the WAL in its own repository when the link is down. It never promotes itself: a lost
  site is declared by a person, because a cut link looks the same as a lost site from the other side, and two
  primaries would split the money.

## Ownership and fencing, on one page

Code review of October 2026, 10: who may make a server the primary, and what stops the old one from taking writes.

| Situation | Who promotes | What fences the old primary | What the applications do |
|---|---|---|---|
| The primary server or its PostgreSQL stops | Patroni, after the leader key expires (30 s) | It is down. When it comes back, Patroni finds another leader and rejoins it as a standby (`pg_rewind`) | 503 `SERVICE_BUSY` with `Retry-After`, then reconnect through HAProxy |
| The primary loses etcd (network cut on its side) | Patroni on the standby side, which still has the vote | Patroni on the old primary cannot renew its key and demotes it to read-only within `retry_timeout` (10 s), before the key expires (30 s) | The same; HAProxy sees `/primary` answer 503 on the old server and cuts its sessions within 3 s |
| Patroni hangs on the primary while PostgreSQL runs | Patroni on the standby, after 30 s | The watchdog (`deploy/ha/patroni.yml`, `mode: required`) restarts the server 5 s before the key expires, so two primaries never take writes at once | The same |
| The whole main site is lost | The on-call lead, by RUNBOOKS.md section 23 | A person: stop the main site's HAProxy and applications, or cut its network, before promoting site B. A cut link looks like a lost site from the other side, so site B never promotes itself | Pointed at site B by DNS or the load balancer, after the promotion |
| Data is damaged | The DBA, by RUNBOOKS.md section 2 | Not a failover: the damaged primary keeps serving or is stopped while a copy is restored to a point in time | Wait for the restored primary |

Three rules hold in every row:

1. **One writer.** Only the server that holds the leader key in etcd accepts writes. HAProxy sends writes only to the
   server whose Patroni answers `/primary`, and the applications' two-host connection strings ask for
   `target_session_attrs=read-write`, so a demoted server is never written to by mistake.
2. **No acknowledged write is lost in an automatic failover.** `synchronous_mode` makes the standby confirm every
   commit; the promoted standby is that one. When it is missing, Patroni drops to asynchronous so bookings continue,
   and the alert `NoSynchronousStandby` tells the on-call engineer that the next failover could lose seconds.
3. **People decide what machines cannot see.** A site is declared lost by the on-call lead, a restore by the DBA; the
   runbooks name the checks to make first (is the main site really unreachable from outside, not only from site B?).

The single-server installation (`docker-compose.yml`) has one database and a streaming replica for reports: there
is no automatic failover; promoting the replica is a decision made by a person (RUNBOOKS.md section 3), after the
primary is stopped.

## Measured

`db/tools/failover_drill.py` writes numbered rows at a steady rate through a two-host connection string, stops the
primary without warning, promotes the standby, and then counts the acknowledged rows the new primary has, while
watching an API instance's `/api/ready`.

Development host, 8 October 2026 (`docs/operations/evidence/failover_drill_dev_2026-10-08.json`), with a 2-second
stand-in for Patroni's detection:

| Standby | Writes acknowledged | Lost | Back to writing | API not ready |
|---|---|---|---|---|
| asynchronous | 638 | 0 | 2.3 s | 2.2 s |
| synchronous | 625 | 0 | 2.4 s | 2.2 s |

With Patroni the detection takes up to its ttl of 30 s, which keeps the failover within the 60-second target.
Staging repeats the drill on the real layout (Patroni, etcd, HAProxy, PgBouncer) before that layout carries
production traffic, then quarterly, and promotes the second site once a year (RUNBOOKS.md, rehearsal schedule).

## What it needs

- Three small hosts for etcd at the main site (one may be the witness on the application server), two database
  servers of equal size, and at the second site one database server and three etcd members (infrastructure
  requirements, `INFRASTRUCTURE_REQUIREMENTS.md`).
- A hardware or kernel watchdog on each database server of the main site (`modprobe softdog` on a virtual machine,
  `/dev/watchdog` owned by postgres): Patroni does not take the leadership without it (`mode: required`).
- A link between the sites with enough bandwidth for the WAL (capacity model: about 50 to 100 GB a day at stage 2).
- The single-server stack (`docker-compose.yml`) keeps its manual promotion of `db-replica` (RUNBOOKS.md section 3)
  until these servers exist.
