# Automatic failover and the second site

Expert review of October 2026, stage D6; reviews of October 2026, H-01. The main site's layout is installed by
`deploy/install.sh` and `deploy/production/ha/install-db-host.sh` (configuration in `deploy/production/ha/` and the
production database image, `deploy/production/db/`); the second site's design is in `deploy/ha/`. Schema file
`1065_failover.sql`, drill tool `db/tools/failover_drill.py`, operations in `docs/operations/RUNBOOKS.md` sections 3
and 23.

## Targets

| Event | Data lost (RPO) | Back to taking bookings (RTO) | Who decides |
|---|---|---|---|
| A database host fails | none: the synchronous standby confirmed every commit | 60 s: Patroni's detection (about 30 s) and the clients' reconnection | Patroni, automatically |
| The main site is lost | the WAL not yet streamed or archived to the second site: seconds, at most 60 s | 30 minutes (the approved RTO): the decision, the promotion, pointing the applications at the second site | the on-call lead, by the runbook |
| Data is damaged (a bad migration, a deleted table) | back to any second in the last 7 days | 30 minutes on new hardware | the DBA, by RUNBOOKS.md section 2 |

The 60-second RPO and 30-minute RTO are the owner's approved targets (8 October 2026); the one-minute failover is
the target of RUNBOOKS.md section 3. A production server on one database host (`MASSLAK_DB_LAYOUT=single`, accepted
by the owner in `MASSLAK_SINGLE_HOST_ACCEPTED`) has no automatic failover: losing the host means a restore, about 30
minutes.

## The production layout (`MASSLAK_DB_LAYOUT=ha`)

```
        application host (10.0.0.10)                     database hosts
  ┌──────────────────────────────────────┐      ┌────────────────────────────────────┐
  │ Caddy → API, worker                   │      │ db1 (10.0.0.11)                    │
  │ PgBouncer ─┐                          │      │   etcd ── Patroni ── PostgreSQL     │
  │            ▼                          │ TLS  │          primary                    │
  │ db         HAProxy → the primary  ────┼─────▶│            │ synchronous streaming   │
  │ db-replica HAProxy → the standby ─────┼─────▶│            ▼ (TLS, verify-full)      │
  │ etcd (the third member, the witness)  │      │ db2 (10.0.0.12)                    │
  └──────────────────────────────────────┘      │   etcd ── Patroni ── PostgreSQL     │
                                                │          synchronous standby        │
                                                └────────────────────────────────────┘
        every WAL segment: archive-push by the primary to pgBackRest's repository off the hosts
```

- **Patroni** (in the production database image; `deploy/production/db/patroni.yml`) holds the leader key in etcd.
  When the primary stops renewing it (ttl 30 s), the synchronous standby is promoted. `synchronous_mode` makes it
  confirm every commit, so the promoted host has every booking and payment the clients were told about.
  `use_pg_rewind` lets the old primary rejoin as the standby without a full copy. What happens while the standby is
  down is the owner's setting (decision 1, `MASSLAK_ZERO_DATA_LOSS`, applied by `deploy/durability.sh` through
  Patroni's REST API): `on` sets `synchronous_mode_strict`, and commits wait rather than be confirmed without a copy
  (`CommitsWaitingForStandby`); `off` lets Patroni drop to asynchronous so bookings continue (`NoSynchronousStandby`).
  With two hosts, `on` also means that while one host is down, writes wait for it to return (RUNBOOKS.md, section 3,
  says when to switch it off).
- **etcd** has three members: one on each database host and the witness on the application host, so the vote that
  elects the primary survives the loss of any one machine.
- **HAProxy** runs on the application host under the names the stack already uses: `db` reaches whichever host
  answers `/primary` on its Patroni API, `db-replica` a standby at most 16 MB behind (`/replica?lag=16MB`), or the
  primary while no standby is up. A host that loses the role is marked down within 3 s and its sessions are cut, so
  clients reconnect to the new primary. PgBouncer, the API's audit connection, the migration and the operator's
  scripts (`backup.sh`, `restore.sh`, `check-archive.sh`) need no change.
- **TLS between every part**, with the internal authority (`deploy/production/init.sh`): one certificate, the
  cluster's, names both hosts, the witness and the names `db` and `db-replica`. PostgreSQL accepts only TLS on the
  network (`hostssl`, scram-sha-256; the replication and rewind logins check the certificate, `verify-full`); the
  clients check it through HAProxy, which passes TLS through; Patroni's REST API is HTTPS; etcd requires a client
  certificate from its members and from Patroni. Patroni and etcd listen only on each host's private address.
- **pgBackRest** archives every WAL segment from whichever host is the primary to the repository off the hosts, and
  each host's cron runs the weekly full and daily differential backups only while it is the primary
  (`masslak-backup-if-primary`). A second repository (the second site's) is `PGBACKREST_REPO2_*` in `deploy/.env`,
  carried to the hosts in their bundles.
- **The applications** may also list the hosts themselves, without HAProxy:
  `postgresql://user:pw@10.0.0.11:5432,10.0.0.12:5432/masslak?target_session_attrs=read-write`. During a failover the
  API answers 503 with `Retry-After: 2` (`SERVICE_BUSY`), and `/api/ready` reports not ready until the pool reaches a
  primary again. Bookings and payments carry idempotency keys, so a client's retry never doubles them.

### Installing it

1. On the application host, in `deploy/.env`: `MASSLAK_DB_LAYOUT=ha`, `MASSLAK_DB_HOSTS=10.0.0.11,10.0.0.12` (the
   database hosts' private IPv4 addresses), `MASSLAK_DB_WITNESS=10.0.0.10` (this host's private address), and
   optionally `MASSLAK_DB_NETWORK` (the private network's range for `pg_hba.conf`; the hosts' own networks by default).
2. `sudo ./deploy/install.sh ...` issues the cluster's certificate, writes one bundle per database host
   (`deploy/production/ha/bundles/db1.tar.gz`, `db2.tar.gz`), starts the witness, and stops at the preflight while
   the database hosts are not running.
3. On each database host, from the same signed release archive, with Docker and cosign installed:
   `sudo ./deploy/production/ha/install-db-host.sh /root/db1.tar.gz` (then `db2.tar.gz` on the other). It checks and
   pulls the signed database image, starts etcd and Patroni, loads the kernel watchdog (`softdog`) and schedules the
   backups. A new cluster starts once etcd has run on all three machines (etcd settles the cluster's version only
   then): the first Patroni to find it ready becomes the primary, the other copies it and becomes its synchronous
   standby. Delete the bundle afterwards (it holds the cluster's key and the database passwords).
4. `sudo ./deploy/install.sh ...` again: the preflight finds one primary and a synchronous standby, and the stack
   starts against them.

Updating: `deploy/update.sh` on the application host, then `install-db-host.sh` with the new release's bundle on the
standby's host first, then on the primary's, which hands the role to the standby before it restarts (a switchover:
no committed write lost, a few seconds of reconnecting). The firewall of each database host lets the other database
host and the application host reach ports 5432, 8008, 2379 and 2380 on the private network, and nothing else.

## Ownership and fencing, on one page

Code review of October 2026, 10: who may make a host the primary, and what stops the old one from taking writes.

| Situation | Who promotes | What fences the old primary | What the applications do |
|---|---|---|---|
| The primary host or its PostgreSQL stops | Patroni, after the leader key expires (30 s) | It is down. When it comes back, Patroni finds another leader and rejoins it as the standby (`pg_rewind`) | 503 `SERVICE_BUSY` with `Retry-After`, then reconnect through HAProxy |
| The primary loses etcd (network cut on its side) | Patroni on the other side, which still has the majority (the other database host and the witness) | Patroni on the old primary cannot renew its key and demotes it to read-only within `retry_timeout` (10 s), before the key expires (30 s) | The same; HAProxy sees `/primary` answer 503 on the old host and cuts its sessions within 3 s |
| Patroni hangs on the primary while PostgreSQL runs | Patroni on the standby, after 30 s | The kernel watchdog (`softdog`, passed to the container) restarts the host 5 s before the key expires, so two primaries never take writes at once | The same |
| The whole main site is lost | The on-call lead, by RUNBOOKS.md section 23 | A person: stop the main site's applications, or cut its network, before promoting site B. A cut link looks like a lost site from the other side, so site B never promotes itself | Pointed at site B by DNS or the load balancer, after the promotion |
| Data is damaged | The DBA, by RUNBOOKS.md section 2 | Not a failover: the damaged primary keeps serving or is stopped while a copy is restored to a point in time | Wait for the restored primary |

Three rules hold in every row:

1. **One writer.** Only the host that holds the leader key in etcd accepts writes. HAProxy sends writes only to the
   host whose Patroni answers `/primary`, and two-host connection strings ask for `target_session_attrs=read-write`,
   so a demoted host is never written to by mistake.
2. **No acknowledged write is lost in an automatic failover.** `synchronous_mode` makes the standby confirm every
   commit; the promoted host is that standby. When it is missing: with zero data loss on (the production default,
   owner's decision 1) commits wait for it; with it off Patroni drops to asynchronous so bookings continue, and the
   alert `NoSynchronousStandby` tells the on-call engineer that the next failover could lose seconds.
3. **People decide what machines cannot see.** A site is declared lost by the on-call lead, a restore by the DBA; the
   runbooks name the checks to make first (is the main site really unreachable from outside, not only from site B?).

## The second site

A Patroni standby cluster (`deploy/ha/patroni-site-b.yml`) streams from the main site's database hosts and falls back
to the WAL in its own repository (repo2) when the link is down. It never promotes itself: a lost site is declared by
a person, because a cut link looks the same as a lost site from the other side, and two primaries would split the
money. Its watchdog (`deploy/ha/site-b-watchdog.sh`, a systemd timer) reports every minute whether it streams from
the main site, how far behind it is and whether the main site's primary answers from there (alerts
`SiteBNotStreaming`, `SiteBLagging`, `MainSiteUnreachableFromSiteB`). The second site is a design until its hosts
exist; it is not installed by `deploy/install.sh`.

## Measured

`db/tools/failover_drill.py` writes numbered rows at a steady rate (20 a second), stops the primary without
warning, and counts the acknowledged rows the new primary has, while watching the API's `/api/ready`.

| Where | Layout | Writes acknowledged | Lost | Back to writing | Evidence |
|---|---|---|---|---|---|
| Development host, 8 October 2026 | stand-in for Patroni's detection (2 s) | 625 | 0 | 2.4 s | `evidence/failover_drill_dev_2026-10-08.json` |
| Development host, 10 October 2026 | this configuration (Patroni 4.0.6, etcd 3.5 with client certificates, HAProxy 2.8, TLS everywhere), native processes, writes through HAProxy, primary killed (`kill -9` of Patroni and PostgreSQL) | 298 | 0 | 25.4 s | `evidence/failover_drill_ha_2026-10-10.json` |
| CI, 10 October 2026 (job "Production with two database hosts", run of `fc7d926`) | the installed layout: three machines on one runner, each database host installed from its bundle with the signed image, the primary's container killed (`docker kill`) | 500 | 0 | 23.3 s | the job's log; every push repeats it with the same assertions (none lost, back within 60 s, the API ready again) |

That first CI run also showed the API staying not ready after the failover, though bookings were back: readiness
required the reports connection to reach a standby, and with none up `db-replica` sends reports to the primary. With
two database hosts that is now accepted, at start and in `/api/ready` (`db.reports_may_reach_the_primary`), PgBouncer
tries the new primary every 2 s instead of 15 (`SERVER_LOGIN_RETRY`), and the drill records whether the API was ready
again when it ended. After each drill the old primary is started again and rejoins
as the synchronous standby (`pg_rewind`). The CI job
also checks that a commit waits while the standby is down with zero data loss on, and that an update of the
primary's host hands the role over first. Staging repeats the drill on its own hosts before the layout carries
production traffic, then quarterly, and promotes the second site once a year (RUNBOOKS.md, rehearsal schedule).

## What it needs

- Two database hosts of equal size and a private network between them and the application host
  (`INFRASTRUCTURE_REQUIREMENTS.md`); the application host carries the third etcd member.
- A kernel or hardware watchdog on each database host (`softdog` on a virtual machine; `install-db-host.sh` loads it).
- For the second site: one database host and three etcd members there, and a link with enough bandwidth for the WAL
  (capacity model: about 50 to 100 GB a day at stage 2).
