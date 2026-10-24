# ADR 0047: The network guard, the security page and the application host without an edge

Status: accepted on 2026-10-24 at the owner's request (docs/31, row 48). Written by an AI agent.

## Context

The owner asked for protection against intrusion and flooding, shown in the platform, and evaluated a list of
measures (docs/31 row 48). Linux with Docker was approved for the application layer, and the owner decided to build
without a Cloudflare edge for now. So Caddy on the host is the only reverse proxy and ends TLS, and the platform must
read the client address safely, limit and block it itself, and show what happens to the operators. Two gaps were
real: the production build shipped source maps, and only the sign-in, MFA and reset paths had a rate limit.

## Decision

- **Source maps.** The web build has none (`app/web/vite.config.ts`). The browser's tools show only the minified
  bundle. Turning off the developer tools or the right mouse button is not done: it is easily bypassed and harms
  use. The server checks every action instead, and printed output carries its reference.
- **Client address.** Forwarded headers are read only from the addresses in `Security:TrustedProxies` (loopback by
  default; the gateway of the API's Docker network in `tools/host/compose.yml`), and only one hop. A client that
  sends `X-Forwarded-For` itself names nothing. Caddy replaces the header from clients, because it has no trusted
  proxies of its own. An edge added later goes into the list, with no code change.
- **API limit.** Every `/api` request counts against its client address: `Security:ApiPerMinute`, 600 by default.
  The front end's files and the health check are not counted. The earlier limits on sign-in (10 a minute), MFA (10
  in 15 minutes) and reset (10 an hour) stay.
- **Temporary block.** `SecurityGuard` counts each 401, 403 and 429 the platform answers to an address. Past
  `Security:RefusalLimit` (40) within `RefusalWindowSeconds` (300), the address is blocked for `BlockMinutes` (30):
  - a row in `plat.IpBlock` (AUTO);
  - a platform audit event IP_BLOCKED (Category SECURITY, Severity HIGH, the address in IpAddress);
  - a warning in the log (event 4801), and a mail to `Security:AlertEmails`.

  A blocked address gets 403 `IP_BLOCKED` before anything else runs. The active blocks are held in memory and read
  again every 30 seconds, so a block made by an operator or another instance applies within that time. If the list
  cannot be read, the last one stays in force. A failure to record a block never turns the refusal into a 500.
- **Never blocked.** Loopback, the trusted proxies and an unknown address are never counted, limited or blocked, and
  an operator cannot block them (`V-SEC-TRUSTED`). A wrong setting therefore cannot shut every user out at once.
- **Operator panel.** The Security page shows the guard's settings, the active blocks and the last 100 security
  events. The Incidents page is the register of DOC-S15:
  - numbered `INC-YYYY-NNN` by the year of detection;
  - statuses OPEN, CONTAINED, RESOLVED, CLOSED;
  - closed only with its root cause, and not changed once closed.

  Reading is open to every operator. Blocking, lifting and incidents need an OPERATOR_ADMIN and a fresh code, and
  each is a SECURITY event in the platform log.
- **Host.** Ubuntu 24.04 with Docker. The templates are in `tools/host/` and described in DOC-S16:
  - UFW: 80 and 443 open, SSH from the administrators' addresses only, ping limited to 5 a second, new connections
    to 443 limited per address;
  - kernel settings: SYN cookies and the reverse-path filter;
  - Caddy: automatic certificates, a JSON access log, timeouts and a body limit;
  - logs: Docker log rotation, a persistent journal, auditd rules;
  - fail2ban: for SSH, and for the addresses the platform keeps refusing in the Caddy log, as a longer ban at the
    firewall;
  - an evidence script that only reads, and a host check that alerts on new ports, new containers, changed keys,
    disk, memory and stopped services.

  Caddy runs on the host, not in a container, because Docker's published ports bypass UFW. The API publishes its
  port on loopback only.

## Consequences

- Two new global tables, `plat.IpBlock` and `plat.SecurityIncident`, are granted to `tp_platform` only. There is no
  migration script: the release is still the baseline.
- A large flood (DDoS) is beyond what one server can absorb. The hosting provider's network protection is asked
  for, and an edge (a CDN, or a local cloud provider's protection if data residency requires it) remains the next
  layer. Adding it changes `Security:TrustedProxies`, the UFW rule for 443 and the fail2ban `ignoreip`.
- Many users of one company behind one NAT address share that address's budget. The values are settings and are
  reviewed after the trial's first weeks.
- Wazuh, for central collection and file-change detection, replaces AIDE before the public launch (P1). Grafana and
  Loki stay optional.
- The guard holds its counters in memory per instance. With more than one API instance, the limit is per instance,
  and the blocks are shared through the table.
- The application image (Dockerfile) and its publish pipeline are still to be written. The compose file is a
  template for them.
