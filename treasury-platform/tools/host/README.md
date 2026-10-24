# Application host: Linux, Docker and Caddy (ADR 0047, DOC-S16)

Templates for the application host. There is no Cloudflare edge (docs/31 row 48), so Caddy is the only trusted proxy.
Every file is a proposal: try it on a test host, then on the real one, and keep the output in the provisioning
record. Values between `<...>` are host-specific and are never written in the repository.

| File | Goes to | What it does |
|---|---|---|
| `ufw.sh` | run once as root | Default deny in; 80/443 open; SSH from the admin addresses only; ICMP echo limited; new connections to 443 limited per address |
| `sysctl-bankfas.conf` | `/etc/sysctl.d/60-bankfas.conf` | SYN cookies, reverse-path filter, no redirects or source routes, larger SYN backlog |
| `Caddyfile` | `/etc/caddy/Caddyfile` (Caddy on the host) | TLS with automatic certificates, JSON access log, timeouts, body limit, proxy to the API |
| `compose.yml` | `/opt/bankfas/compose.yml` | The API on a fixed network, its port on loopback only, trusting the network's gateway (Caddy) only |
| `docker-daemon.json` | `/etc/docker/daemon.json` | Log rotation, no new privileges, containers on the default bridge isolated |
| `journald-bankfas.conf` | `/etc/systemd/journald.conf.d/60-bankfas.conf` | Persistent journal with size limits |
| `auditd-bankfas.rules` | `/etc/audit/rules.d/60-bankfas.rules` | Watches accounts, sudo, SSH, keys, Docker, Caddy and the application's secrets |
| `fail2ban/jail.local`, `fail2ban/filter.d/bankfas-caddy.conf` | `/etc/fail2ban/` | Bans at the firewall: SSH failures, and addresses the platform keeps refusing in the Caddy log |
| `collect_evidence.sh` | run as root on suspicion | DOC-S15 steps 2, 5, 6 and 9: copies the logs with a timestamp and checksums, lists processes, ports, containers, users and keys; changes nothing |
| `check_host.sh` | systemd timer every 5 minutes | Alerts on new listening ports, new containers, changed `authorized_keys`, disk and memory pressure, a stopped service |

The application's own guard (per-address limit, temporary blocks, the security page of the operator panel) is in
`app/src/BankFas.Api/Infrastructure/SecurityGuard.cs`; its values are the `Security` section of the configuration.
