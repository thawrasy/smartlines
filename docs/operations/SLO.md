# Service levels and monitoring

The service level objectives (SLOs) below are **proposed for the owner's approval** (audit T3-16). Until approved they
drive the alerts as written. The numbers fit the first measurements (`PERFORMANCE_BASELINE.md`) and must be confirmed on
staging at the expected peak.

**How it works:**
- **Measurement:** `GET /api/metrics` exposes request counts and latency per route (grouped as below) and the
  database's operational metrics (`sys.ops_metrics`). It answers only with the `MASSLAK_METRICS_TOKEN` bearer token.
- **Monitoring stack:** Prometheus scrapes every API instance (`deploy/monitoring/prometheus.yml`) and evaluates
  `deploy/monitoring/alerts.yml`. Alertmanager routes severity `page` to the on-call engineer and `ticket` to the team
  queue. Grafana shows `deploy/monitoring/grafana-dashboard.json`.
- **CI:** checks the rules and proves with `promtool` that they fire (`alerts_test.yml`).

## Objectives

| Service (route group) | SLI | Objective (30 days) | Alert |
|---|---|---|---|
| Booking and payment (`booking`, `payment`) | Requests answered without a 5xx | 99.9 % | Fast burn: 2 % of the budget in 1 h (page). Slow burn over 6 h (ticket) |
| Booking (`booking`) | Latency | p95 ≤ 0.8 s, p99 ≤ 1.5 s | p99 > 1.5 s for 10 min (page) |
| Search (`search`) | Latency, availability | p95 ≤ 0.3 s, 99.9 % | p95 > 0.5 s for 15 min (ticket) |
| Tracking ingestion (`tracking`) | Positions accepted without a 5xx | 99.5 %, p95 ≤ 0.5 s | 5xx > 0.5 % for 10 min (page) |
| Notifications and webhooks | Age of the oldest event waiting in the outbox | ≤ 2 min for 99 % of the time | > 5 min for 10 min (page) |
| Money | Wallets reconcile with the ledger | always zero mismatches | any mismatch (page) |
| Recovery | WAL archived | the latest archive ≤ 60 s old (RPO 60 s) | > 5 min, or any failure (page) |
| Upkeep | Daily job succeeds | every 24 h | none for 26 h (page) |

**Error budget:** 99.9 % allows 43 minutes of failed booking traffic a month. When half the budget is spent, releases
other than fixes stop until it recovers.

## Database health watched

| Metric | Alert |
|---|---|
| Connections against `max_connections` | above 80 % for 5 min |
| Sessions waiting on locks | more than 10 for 2 min (stop a migration: `MIGRATION_PLANS.md`) |
| Longest transaction, sessions idle in a transaction | over 5 min, or more than 5 idle |
| Deadlocks | any in 15 min |
| Replica lag | over 30 s for 5 min |
| Dead rows, time since vacuum on hot tables | over 5 million, or 7 days |
| Transaction id age | over 1.2 billion |
| Position partitions for today and tomorrow | one missing for 15 min |
| Files waiting for the virus scan | oldest over 15 min |
| Break-glass access ended without review | any after 24 h |

## On call

| Topic | Arrangement |
|---|---|
| Rota | One engineer on call each week, with a second named as backup |
| Paging | Severity `page` pages at any hour; acknowledge within 15 minutes, start the matching runbook section (every alert names it) |
| Tickets | Severity `ticket` is handled the next working day |
| Drills | One alert drill per quarter: fire a test alert, confirm the page arrives, run the runbook, record the time to acknowledge |
| Records | Every page gets a short incident record. A severity 1 incident gets a blameless review within five working days (runbook section 1) |

## Still to do before launch

1. The owner approves or adjusts these objectives.
2. Deploy Prometheus, Alertmanager and Grafana next to the stack, with the token in `metrics_token`.
3. Connect Alertmanager to the on-call phones.
4. Run the first alert drill.
