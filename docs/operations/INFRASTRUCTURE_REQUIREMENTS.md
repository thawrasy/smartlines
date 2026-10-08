# Infrastructure, hosting and software requirements (October 2026)

What must be in place before the system files are uploaded to a server: servers per stage, storage, memory, network,
operating system and software, the database and its settings, external services, the hosting providers recommended for a
full trial before launch, and the monthly cost per stage. Sizes come from [CAPACITY_MODEL.md](CAPACITY_MODEL.md);
recovery and service targets from [SLO.md](SLO.md); the gates from [LAUNCH_GATES.md](LAUNCH_GATES.md).

## 1. Summary

- **Database:** PostgreSQL 16 with PostGIS 3.4 and the extensions `pgcrypto`, `citext`, `pg_trgm`, `btree_gist`
  (`pg_stat_statements` recommended). No other engine fits: tenant isolation (row-level security) and the money rules
  (balanced double entry, four eyes) are enforced inside the database.
- **Operating system:** Ubuntu Server 24.04 LTS (or 22.04 LTS) with Docker Engine and the Compose plugin. Everything
  else runs in containers and is installed by `deploy/install.sh`.
- **Full trial:** one server with 8 dedicated vCPU, 32 GB RAM, 240 GB NVMe or more, plus an object storage bucket.
- **Pilot launch (selected cities):** primary and replica database servers (16 vCPU, 64 to 128 GB), two application
  servers, one monitoring server.
- **Stage 1 (up to 3 M operations a day):** primary 32 vCPU / 256 GB / 4 TB NVMe with a replica, 4 to 12 API instances.
- **Trial hosting:** Hetzner Cloud or OVHcloud for cost, AWS me-central-1 (UAE) for load testing and proximity. No
  provider publicly confirms accounts for companies registered in Syria: confirm with sales, or contract through an
  entity registered abroad.

## 2. What runs on the server

| Service | Role | Image | Reachable from |
|---|---|---|---|
| `caddy` | HTTPS, automatic Let's Encrypt certificates, HTTP/3 | `caddy:2-alpine` | the internet (80, 443) |
| `app` | API, web interface, public site | `masslak` (Python 3.12-slim, built locally) | Caddy |
| `worker` | outbox delivery (e-mail, SMS, webhooks), file scanning, daily upkeep | `masslak` | nothing |
| `egress` | Squid forward proxy, the only way out, allowlisted names only | `masslak-egress` | `app`, `worker` |
| `pgbouncer` | transaction pooling | `edoburu/pgbouncer:v1.23.1-p3` | `app`, `worker` |
| `db` | primary database | `postgis/postgis:16-3.4-alpine` | internal network |
| `db-replica` | streaming replica for reports and failover | `postgis/postgis:16-3.4-alpine` | internal network |
| `migrate` | one-shot schema build or upgrade, login roles | `masslak` | nothing |

Staging and production add (`deploy/staging`): ClamAV 1.4, pgBackRest 2.x, Prometheus 2.53.2, Alertmanager 0.27.0,
Grafana 11.2.2.

## 3. Environments and stages

| Environment or stage | Purpose | Expected volume | Move on when |
|---|---|---|---|
| Trial | Every portal and app with demo data; team training; partner demos | team and partners | the owner accepts the functions |
| Staging | Launch gates: restore drill, load at 1x/2x/5x, migration rehearsal, alert drill, penetration test | production-like data | all nine gates closed |
| Pilot | Releases 1A then 1B in selected cities and lines, a few carriers | up to about 300,000 operations a day | primary CPU above 60 % at the peak, or 300,000 a day |
| Stage 1 | All governorates | up to 3 M a day | thresholds in section 4.5 |
| Stage 2 | Shuttle, freight, school transport at scale | 3 to 20 M a day | above 20 M a day or 2 billion ledger rows |
| Stage 3 | Distribution by carrier | above 20 M a day | — |

## 4. Servers per stage

### 4.1 Trial (one server)

| Item | Minimum | Recommended for a full trial |
|---|---|---|
| CPU | 4 vCPU | 8 dedicated vCPU |
| Memory | 16 GB | 32 GB |
| Disk | 160 GB SSD | 240 to 400 GB NVMe |
| Network | static IPv4, 1 TB a month | IPv4 and IPv6, 5 TB a month |
| Off-server storage | — | 250 GB object storage bucket for backups |

The absolute functional minimum (2 vCPU, 4 GB, 40 GB, `deploy/README.md`) runs the stack but not a full trial with demo
data, apps and reports.

### 4.2 Staging

| Role | Count | vCPU | RAM | Disk | Notes |
|---|---:|---:|---|---|---|
| Primary database | 1 | 16 | 128 GB | 2 TB NVMe | raised to 32 vCPU / 256 GB for the 5x test |
| Standby | 1 | 16 | 128 GB | 2 TB NVMe | failover drill |
| App, worker, ClamAV | 2 | 8 | 16 GB | 100 GB | behind a load balancer |
| Monitoring | 1 | 4 | 8 GB | 200 GB | Prometheus, Alertmanager, Grafana |
| Load generator | 1 | 8 | 16 GB | 50 GB | outside the server network, during tests only |
| Object storage | — | — | — | 2 TB | WAL archive and backups |

Rent staging by the hour: the 5x test needs a larger database server for a few days only.

### 4.3 Pilot

| Role | Count | vCPU | RAM | Disk | Notes |
|---|---:|---:|---|---|---|
| Primary database | 1 | 16 | 64 to 128 GB | 2 × 1.92 TB NVMe, RAID 1 | dedicated server or memory-optimised instance |
| Replica | 1 | 16 | 64 to 128 GB | as primary | reports and failover, another site if possible |
| App and worker | 2 | 8 | 16 GB | 100 GB | Caddy, app, worker, egress, ClamAV on each |
| Monitoring | 1 | 4 | 8 GB | 200 GB | separate from production servers |
| Object storage | — | — | — | 2 to 5 TB | backups and WAL archive |
| Audit archive | — | — | — | 500 GB | bucket with object lock in a separate account |

### 4.4 Stage 1

| Role | Count | Size | Notes |
|---|---:|---|---|
| Primary database | 1 | 32 vCPU, 256 GB, 4 TB NVMe | PgBouncer in front |
| Replica | 1 | as primary | reports and failover |
| API instances | 4 to 12 | 2 vCPU, 4 GB each | behind a load balancer |
| Workers | 2 | 2 vCPU, 4 GB | |
| Redis | 3 | 2 vCPU, 8 GB | shared rate-limit counters |
| Object storage and CDN | — | 5 TB and more | |
| Monitoring | 1 to 2 | 8 vCPU, 16 GB | 30 days of metrics |

**Redis:** rate-limit counters are kept in each API instance's memory today (`backend/app/ratelimit.py`), which is
correct for one instance. Move them to a shared Redis before running several instances behind the proxy.

### 4.5 Stages 2 and 3 and the thresholds between stages

See [CAPACITY_MODEL.md](CAPACITY_MODEL.md) section 6: stage 2 is a 64 vCPU / 512 GB / 16 TB primary with two replicas and
a telemetry cluster; stage 3 distributes by `company_id` (Citus) or moves freight and school transport to their own
cluster. Thresholds: positions above 500 a second, primary CPU above 60 % at the peak for two weeks, commit p99 above
20 ms, WAL above 150 GB a day, outbox pending age above 2 minutes, ledger above 2 billion rows.

## 5. Storage

| Type | Use | Specification |
|---|---|---|
| Local NVMe | database files and WAL | data-centre NVMe, RAID 1 or 10, at least 50,000 IOPS |
| Server disk | OS, containers, local document store | SSD, 100 GB or more |
| S3-compatible object storage | backups, WAL archive, second copy of documents | another site or account |
| Bucket with object lock (WORM) | signed audit archive | separate account, compliance mode, 10-year retention |

Data volumes at 10 M operations a day are in [CAPACITY_MODEL.md](CAPACITY_MODEL.md) section 4 (steady size 7 to 8 TB in
the database plus about 2 TB of growth a year, 175 to 350 GB of compressed WAL archive). The pilot is 30 to 50 times smaller.

## 6. Memory and database settings

Starting points, tuned after the staging load test:

| Setting | Trial (32 GB) | Pilot (128 GB) | Stage 1 (256 GB) |
|---|---|---|---|
| `shared_buffers` | 8GB | 32GB | 64GB |
| `effective_cache_size` | 20GB | 96GB | 192GB |
| `work_mem` | 16MB | 32MB | 64MB |
| `maintenance_work_mem` | 1GB | 2GB | 4GB |
| `max_connections` (behind PgBouncer) | 200 | 300 | 400 |
| `max_wal_size` | 8GB | 32GB | 64GB |
| `checkpoint_timeout` | 15min | 15min | 15min |
| `random_page_cost` / `effective_io_concurrency` | 1.1 / 200 | 1.1 / 200 | 1.1 / 256 |
| `huge_pages` | try | on | on |
| `wal_level` / `archive_timeout` | replica / 60 | replica / 60 | replica / 60 |
| `track_functions` | pl | pl | pl |
| `shared_preload_libraries` | pg_stat_statements | pg_stat_statements | pg_stat_statements |

`archive_timeout = 60` keeps the approved RPO of 60 seconds; `track_functions = pl` feeds the `TriggerCostOverBudget`
alert. Each API instance needs about 300 to 500 MB, the worker about 300 MB, ClamAV 1.5 to 3 GB.

## 7. Software to install before uploading the system

### 7.1 On the host

`deploy/server-setup.sh` (called by `deploy/install.sh`) installs everything except the OS and git.

| Software | Version | Purpose |
|---|---|---|
| Ubuntu Server | 24.04 LTS (or 22.04 LTS), 64-bit | operating system |
| git | 2.x | fetch the system files (install by hand) |
| Docker Engine | 27 or later | containers |
| Docker Compose plugin | v2.24 or later | the stack |
| ufw | with the OS | firewall: 22, 80, 443 only |
| fail2ban | with the OS | repeated sign-in attempts |
| unattended-upgrades | with the OS | security updates |
| cron | with the OS | nightly backup at 02:15 |
| age | 1.1 or later | backup encryption (recommended) |
| chrony or systemd-timesyncd | with the OS | time sync (signatures, one-time codes) |

### 7.2 Database

- **Engine:** PostgreSQL 16 + PostGIS 3.4.
- **Extensions:** `postgis`, `pgcrypto`, `citext`, `pg_trgm`, `btree_gist`, plus `pg_stat_statements`.
- **Roles** (created by `migrate`): `masslak_owner` (schema owner, migrations only), `masslak_app` (API and worker, under
  row-level security), `masslak_readonly` (reports on the replica), `masslak_auditor` (audit and security logs),
  `replicator`.
- **Self-managed or managed:** self-managed (in the container or on a dedicated server) for the trial and pilot. The
  schema needs superuser for some statements (the DDL audit event triggers of file 1047) and pgBackRest needs the data
  directory. A managed service (Amazon RDS, Azure Database for PostgreSQL) is possible later after a full compatibility
  run: load the schema, pass the 399 database checks, confirm the extensions, event triggers and SECURITY DEFINER roles.

## 8. Network, domain, certificates

| Item | Requirement |
|---|---|
| Domain | `masslak.com` (and a `.sy` domain if the owner wants one) with `www` |
| DNS | A and AAAA for the domain and `www`; CAA allowing `letsencrypt.org`; MX, SPF, DKIM, DMARC for mail |
| Certificates | automatic (Caddy, Let's Encrypt); apps pin ISRG Root X1 and X2 |
| Open ports | 80 and 443; 22 with keys only, from admin addresses |
| Outbound | through `egress` only, to the names in `deploy/egress/allowlist.txt` |
| Bandwidth | trial 1 to 5 TB a month; pilot about 10 TB; stage 1 30 to 60 TB |
| DDoS | provider protection, or a CDN with a web application firewall (check availability for the account) |
| Time zone | UTC on servers; the platform shows Damascus time |

## 9. External services and agreements

| Service | Need | Options | By |
|---|---|---|---|
| Payment provider | wallet top-up, card, instalment and financing payments (cash at the counter and pay later need none; see PAYMENT_OPTIONS.md) | a PSP licensed under the Central Bank of Syria e-payment framework (August 2026); a bank working with Visa and Mastercard; local e-wallets; instalment and travel-financing companies where licensed | when the electronic options open |
| SMS gateway | one-time codes, booking messages | local mobile operators or a licensed aggregator; sender name registration | pilot |
| SMTP relay | tickets, receipts, support replies | a transactional mail provider (after confirming the account is accepted) or an own relay with SPF and DKIM | partner trial |
| Object storage | backups, archive | the hosting provider's S3-compatible storage; separate account for the audit archive | trial |
| Key management | production encryption keys (1B) | HashiCorp Vault or OpenBao, or a cloud KMS | general launch |
| App stores | passenger and driver apps | Google Play developer account; Apple Developer Program (may need an entity registered outside Syria) | pilot |
| Search consoles | public site indexing | Google Search Console, Bing Webmaster Tools, Google Business Profile | trial |
| Penetration test | launch gate 8 | independent security firm | general launch |

## 10. Backup, recovery, monitoring

| Item | Approved target | How |
|---|---|---|
| RPO | 60 s | WAL archived every 60 s by pgBackRest to off-server storage |
| RTO | 30 min | restore drill on a new host in staging (gate 1) |
| Nightly backup | 02:15 | `pg_dump` plus the document store, SHA-256 checksums, `age` encryption |
| Off-site copy | daily | copy the backup directory to another site or account |
| Restore rehearsal | quarterly | `restore.sh` on a test server, then wallet and ledger checks |
| Booking and payment availability | 99.9 % | fast-burn alert at 2 % of the budget in 1 h |
| Search | p95 ≤ 0.3 s | alert above 0.5 s for 15 min |
| Time to acknowledge | ≤ 15 min | 24/7 on-call and an alert drill (gate 5) |

## 11. Hosting for the full trial

Prices from independent trackers, July to September 2026, excluding VAT. Providers raised prices several times in 2026
(memory costs); check at order time.

| Rank | Provider and region | Trial server | Approximate monthly price | Strengths | Caveats |
|---:|---|---|---|---|---|
| 1 | Hetzner Cloud (Germany, Finland) | CCX33: 8 dedicated vCPU, 32 GB, 240 GB NVMe | EUR 138 (EUR 62 before June 2026) | best price for performance, hourly billing, object storage | four price changes in 2026, strict identity checks, Syrian accounts unconfirmed |
| 2 | AWS me-central-1 (UAE) | m7i.2xlarge: 8 vCPU, 32 GB, plus gp3 | about USD 361 plus disk and transfer | closest region, managed services, path to production; Saudi region announced for December 2026 | highest cost, egress fees, account eligibility to confirm |
| 3 | DigitalOcean (Frankfurt, Amsterdam) | General Purpose 8 vCPU, 32 GB | about USD 252 with 6 TB transfer | simple, per-second billing, one-click backups | its terms historically listed Syria |
| 4 | OVHcloud (France, Germany) | VPS-4: 8 cores, 24 GB, 200 GB; or Advance-1 dedicated | about EUR 23 (VPS); from EUR 105 plus setup (dedicated) | cheapest functional trial, anti-DDoS included | price rises August and October 2026, slower support, 24 GB on the VPS |
| 5 | Azure (UAE) or Google Cloud (Doha, Dammam) | 8 vCPU, 32 GB | close to AWS | when a government or bank requires a given provider | cost and account procedures |

**Recommendation.** Full trial on Hetzner Cloud CCX33 with Hetzner Object Storage (about EUR 140 to 160 a month), or
OVHcloud VPS-4 for the cheapest functional trial (about EUR 25 to 40). Staging and load tests on AWS me-central-1, hourly,
for the two to four weeks of tests. Production is decided after the trial and a legal review of data residency; if data
must stay in Syria, the same stack moves to a local data centre (SilkLink data centres announced in February 2026,
expected in 18 to 24 months).

**Accounts and compliance.** Most US and EU economic sanctions were lifted in 2025 (US EO 14312; EU Regulation
2025/1098), but no provider publicly confirms accounts for companies registered in Syria. Ask sales before ordering or
contract through a sister company registered in the UAE, Turkey or the EU. Some export controls on software and cloud
services remain; review the provider's terms.

## 12. Monthly infrastructure cost (USD, 2026, excluding tax)

| Stage | Servers | Budget provider (Hetzner, OVHcloud) | Hyperscaler on demand (AWS) |
|---|---|---|---|
| Trial | one server and object storage | 30 to 180 | 400 to 500 |
| Staging (during tests) | six servers and a load generator | 800 to 1,200 | 2,500 to 4,000 |
| Pilot | 2 database, 2 app, monitoring, storage | 900 to 1,500 | 2,800 to 4,000 |
| Stage 1 | two large database servers, up to 12 API, Redis, storage, CDN | 3,000 to 5,000 | 8,000 to 12,000 |
| Stage 2 | 64 vCPU primary, two replicas, telemetry, search, warehouse | 10,000 to 18,000 | 25,000 to 45,000 |

One- or three-year commitments lower hyperscaler prices by 30 to 40 %. Payment provider fees, SMS and the penetration
test are in the feasibility study.

## 13. Checklist before uploading the system

1. Server with Ubuntu 24.04 LTS and a static IP.
2. Domain with A and AAAA records for `masslak.com` and `www`, propagated (the certificate is issued on first start).
3. Administrator SSH key; password sign-in disabled.
4. Object storage bucket for backups in another account or site.
5. Password manager or secret store for the keys section of `deploy/.env`.
6. ACME e-mail and first administrator e-mail.
7. Trial: keep the simulated payment gateway. Production: payment provider, SMS gateway and SMTP relay details, their
   names added to the egress allowlist.
8. Contact details in `deploy/.env` (shown on the contact page).
9. `deploy/install.sh --domain ... --email ... --admin-email ...` (`--demo` for a trial only).
10. First sign-in, second factor enrolled, first sign-in details moved to the password manager and the file shredded.
11. One manual backup restored on another server before any real data.

## Sources

- Hetzner June 2026 price change: privatedevops.com/news/hetzner-june-2026-cloud-price-increase-what-to-do;
  northflank.com/blog/hetzner-cloud-server-price-increases.
- DigitalOcean and Hetzner prices (July 2026): spendark.com/instances/g-8vcpu-32gb; spendark.com/compare/ccx33-vs-voc-g-8c-32gb.
- AWS m7i.2xlarge by region: devzero.io/instances/aws/m7i.2xlarge.
- OVHcloud: ovhcloud.com/en/bare-metal/advance/prices; vpsbenchmarks.com (VPS-4 trial, September 2026).
- Sanctions: US Treasury (EO 14312); EU Regulation 2025/1098; remaining export controls: goodwinlaw.com (October 2025).
- Central Bank of Syria e-payment framework (August 2026): english.enabbaladi.net.
- SilkLink and stc group (February 2026): meatechwatch.com.
