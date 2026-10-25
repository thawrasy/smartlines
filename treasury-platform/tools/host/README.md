# Application host: Linux, Docker and Caddy (ADR 0047, DOC-S16)

Templates for the application host. There is no Cloudflare edge (docs/31 row 48), so Caddy is the only trusted proxy.
Every file is a proposal: try it on a test host, then on the real one, and keep the output in the provisioning
record. Values between `<...>` are host-specific and are never written in the repository.

| File | Goes to | What it does |
|---|---|---|
| `ufw.sh` | run once as root | Default deny in; 80/443 open; SSH from the admin addresses only; ICMP echo limited; new connections to 443 limited per address |
| `sysctl-bankfas.conf` | `/etc/sysctl.d/60-bankfas.conf` | SYN cookies, reverse-path filter, no redirects or source routes, larger SYN backlog |
| `Caddyfile` | `/etc/caddy/Caddyfile` (Caddy on the host) | TLS with automatic certificates, JSON access log, timeouts, body limit, proxy to the API |
| `compose.yml` | `/opt/bankfas/compose.yml` | The API and the worker on a fixed network, the API's port on loopback only, trusting the network's gateway (Caddy) only; images from `app/deploy/Dockerfile` (the API's carries Chromium and an Arabic font for the PDF, ADR 0051) |
| `docker-daemon.json` | `/etc/docker/daemon.json` | Log rotation, no new privileges, containers on the default bridge isolated |
| `journald-bankfas.conf` | `/etc/systemd/journald.conf.d/60-bankfas.conf` | Persistent journal with size limits |
| `auditd-bankfas.rules` | `/etc/audit/rules.d/60-bankfas.rules` | Watches accounts, sudo, SSH, keys, Docker, Caddy and the application's secrets |
| `fail2ban/jail.local`, `fail2ban/filter.d/bankfas-caddy.conf` | `/etc/fail2ban/` | Bans at the firewall: SSH failures, and addresses the platform keeps refusing in the Caddy log |
| `collect_evidence.sh` | run as root on suspicion | DOC-S15 steps 2, 5, 6 and 9: copies the logs with a timestamp and checksums, lists processes, ports, containers, users and keys; changes nothing |
| `check_host.sh` | systemd timer every 5 minutes | Alerts on new listening ports, new containers, changed `authorized_keys`, disk and memory pressure, a stopped service |
| `download_breached.sh` | run once, then monthly, as a user that can write `/srv/bankfas/breached` | The leaked-password list (DQ-S04-1): one file per SHA-1 prefix from the public range API, resumable, about 30 GB |
| `api.env.example`, `worker.env.example` | `/opt/bankfas/api.env`, `/opt/bankfas/worker.env` (root, 600) | The settings of the two processes; each has only its own database logins (docs/54 H-05) |
| `site.conf.example` | `/opt/bankfas/site.conf` (root, 600) | Every value of the host in one file (docs/55) |
| `provision_app_host.sh` | run as root, again after any change of site.conf | Folders and owners, the master key once, the env files, compose.yml and the Caddyfile written from site.conf, the secrets put in place (docs/54 H-05) |
| `check_ready.sh` | run as root before the first start and after every change | Read-only readiness: permissions, Production settings, the leaked-password list, images, Caddy, firewall, DNS, the database and the mail relay (docs/54 R-02a) |

The application's own guard (per-address limit, temporary blocks, the security page of the operator panel) is in
`app/src/BankFas.Api/Infrastructure/SecurityGuard.cs`; its values are the `Security` section of the configuration.

## Before the first start (docs/53, docs/54, ADR 0053)

The whole order, both servers, is `docs/54-deployment-runbook.md`.

- **Master keys:** `/opt/bankfas/secrets/master-keys/<name>.key`, each the base64 of 32 random bytes
  (`openssl rand -base64 32`), owned by 10001 and mode 400; `Keys__File__Current=file:<name>` in `api.env` and
  `worker.env`. Keep an offline copy: without it nothing encrypted can be opened again. Rotation adds a new file and
  makes it current; the old one stays.
- **Data protection keys:** `/srv/bankfas/dataprotection`, owned by 10001; wrapped by the master key.
- **Leaked-password list:** `download_breached.sh /srv/bankfas/breached`, then `Passwords__BreachedList__Directory`.
- **Malware scan:** ClamAV (`Scanning__Provider=clamav`, `Scanning__Host`, `Scanning__Port`).
- **Mail:** `Mail__Smtp__Host` and the account of the relay.
- **Database:** a certificate the containers trust on SQL Server (no `TrustServerCertificate` outside tests).
- **Images:** built on the host or a build machine; behind a TLS-inspecting proxy pass its CA with
  `--secret id=extra_ca,src=<ca.pem>`, and without access to Playwright's servers pass Chromium with
  `--build-context chromium=<path>/chrome-linux` (`app/deploy/Dockerfile`).
- **Pilot check of the images:** `tools/ci/image_pilot.sh` after `db_ci.sh` on a throwaway server.
