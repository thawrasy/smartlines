# The security watch

Wave 7 (owner's notes 20-32), migration `1167_security_watch.sql`. It builds on the platform shield of `1142` (firewall,
traffic watch, shield level), the shared rate limits of `1068` and the monitoring of the production profile.

## What it adds

| Part | Where | What it does |
| --- | --- | --- |
| Access sweep | `backend/tests/test_access_sweep.py` | Every read address of every portal, taken from the application itself, is refused to anyone not signed in and to the other portals' sessions; none answers with a server error |
| Secret scan | CI (gitleaks, `.gitleaks.toml`) | The whole tree is scanned for keys and passwords on every push |
| Image scan | CI (Grype) | The built image fails on a critical vulnerability that has a fix |
| Web scan | CI (ZAP baseline) | The running stack is scanned passively; the report is kept as a CI artifact |
| Security figures | `sys.security_metrics()` | Open traffic alerts by severity, firewall and bait hits of the last 15 minutes by rule, failed sign-ins of the last 15 minutes, active blocks by source, the shield level, exceptions waiting and ending |
| Security alerts | `deploy/monitoring/alerts.yml` (group `masslak-security`) | Bait touched, attack patterns surge, failed sign-ins surge, critical traffic alert, lockdown, raised shield for two hours, exception waiting a day, exception ending within a week |
| Alert relay | `POST /api/security/relay/alertmanager` | Alertmanager's security route posts here with a bearer token; each alert goes to the Telegram chats of `security.alert_telegram_chats`, in Arabic and English |
| Bait addresses | `shield.BAIT`, `sec.bait_touch` | `/api/internal`, `/api/debug`, `/api/v0`, `/api/private`, `/backup`, `/db-backup`: a touch is recorded and the address blocked at once for a day (doubled for an address blocked before); the answer is an ordinary "not found" |
| Exception register | `sec.shield_exception`, `/api/security/exceptions` | Letting an address through the shield is asked by one person and approved by another, with an end date no later than `security.exception_max_days` (90); the approval writes the ALLOW rule, a revocation or the end date removes it. Direct ALLOW rules are refused (`USE_EXCEPTION_REGISTER`) |
| Sign-in limits | `ratelimit.check_device_and_network` | Per device identifier of the mobile apps (`security.signin_device_per_minute`, 10) and per network (`security.signin_network_per_minute`, 600, never below the per-address limit; IPv4 /24 and IPv6 /48 by default), on top of the per-address and per-account limits |
| Logs | `deploy/production/logs` | Alloy reads the containers' log files and the host's sign-in and fail2ban logs (read-only, never the Docker socket) and ships them to Loki, kept 30 days; Grafana has a Loki datasource and the **Masslak security** dashboard |
| Server hardening | `deploy/server-setup.sh` | Further kernel settings (pointer and log hiding, ptrace scope, BPF, protected links, no core files from privileged programs), shared memory without execution. SSH settings are left for wave 9 with the owner |
| Configuration backup | `deploy/config-backup.sh` | The server's own configuration (environment, secrets, certificates, host hardening, cron, package list), encrypted with age, weekly and copied off the server; restore guide `docs/operations/SERVER_CONFIG_RESTORE.md` |

## Decisions

* **Recovery targets** stay as approved: RPO 60 seconds, RTO 30 minutes.
* **Bait answers look like nothing.** A bait address answers 404 with the platform's usual body, so a scanner learns
  nothing from it. Only `/backup/` is named in `robots.txt`; the rest are found only by guessing.
* **An exception never lasts forever.** The end date is required and capped; the register keeps who asked, who
  approved, why and when it ended. The person who asked cannot approve, even as an administrator.
* **No chat is sent alerts by default.** The platform names the security staff's Telegram chats in
  `security.alert_telegram_chats`; until then the relay accepts alerts and sends none.
* **Alloy reads files, not the Docker socket.** The socket would give it control of the host.

## Checks

* `backend/tests/test_security_watch.py`: bait paths and routes never overlap, network keys, a bait touch blocks at
  once and looks like nothing, an exception needs a second person and an end date and lets the address through, the
  device limit, the figures reach the metrics, the relay's token.
* `db/tests/run_tests.sql` (1167): bait blocks once, exception rules (length, same person, frozen request, approval
  writes the ALLOW rule, revocation removes it), figures, settings.
* `deploy/monitoring/alerts_test.yml`: every security alert fires on its figure.
