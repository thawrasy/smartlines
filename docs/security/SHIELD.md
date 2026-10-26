# The platform shield

**Owner's request, October 2026.** Build the system and its website with a software firewall that hardens the code
against vulnerabilities; defences that stop background-command floods (ping and the like) from exhausting the servers;
a control unit that alerts the platform manager (developer and admin) about abnormal load so traffic can be held until
it is checked; layered hardening against illegitimate entry to the backend and frontend; a block on any double
(concurrent) sign-in for a user, to protect passengers' wallets and rights; and protection of the browser source code
and source maps from misuse. Then, later: deploy to a private Linux server through a Linux-server specialist, build the
mobile apps, and verify the system against breaches and for strength (penetration testing).

This document describes what was built (migration 1142 and the layers around it) and the forward plan for the three
later items. The shield **extends** the security the platform already had — `sec.ip_rule`, the shared rate limits
(`sec.rate_bucket`), the content security policy, the egress proxy, the guard module, fail2ban — rather than
duplicating it.

## 1. What a request passes through

A request from the public internet crosses four layers before it reaches a route handler. Each layer is independent,
so a gap in one is still covered by the next (defence in depth).

```
 Internet
    │
 ┌──┴───────────────────────────────────────────────────────────┐
 │ 1. Host kernel (deploy/server-setup.sh)                        │
 │    ICMP/ping rate limit · SYN-flood cookies · rp_filter ·      │
 │    per-source new-connection limit in DOCKER-USER (iptables)   │
 └──┬───────────────────────────────────────────────────────────┘
    │
 ┌──┴───────────────────────────────────────────────────────────┐
 │ 2. Edge (Caddy, deploy/Caddyfile)                              │
 │    HTTPS · HSTS · security headers · body size cap ·           │
 │    unexpected methods → 405 · probe paths and *.map → 404 ·    │
 │    slow-upstream timeouts                                      │
 └──┬───────────────────────────────────────────────────────────┘
    │
 ┌──┴───────────────────────────────────────────────────────────┐
 │ 3. API middleware (backend/app/middleware.py + shield.py)      │
 │    IP rules (sec.ip_decision) · shield level (NORMAL/          │
 │    ELEVATED/LOCKDOWN) · application firewall (WAF) ·           │
 │    rate limits · traffic counters                             │
 └──┬───────────────────────────────────────────────────────────┘
    │
 ┌──┴───────────────────────────────────────────────────────────┐
 │ 4. Route + database (RLS, isolation context, step-up)          │
 └────────────────────────────────────────────────────────────────┘
```

## 2. The software firewall (WAF)

`backend/app/shield.py` inspects each request before its handler runs and before the body is parsed as a model. It
looks for unambiguous attack patterns and for the noise of automated tooling:

- **Injection families** — SQL, script/HTML, OS command (including `;ping`, `&&curl`, `` `wget` `` and the backtick and
  `$(...)` forms the owner called out), template/expression (`${jndi:…}`, `{{7*7}}`), cloud-metadata addresses
  (`169.254.169.254` and the Google/Alibaba/IPv6 equivalents), path traversal and null bytes.
- **Probes** for files no route serves (`/.env`, `/.git/…`, `/wp-admin`, `/phpmyadmin`, `*.php`) and for **source maps**
  (`*.js.map`) — a missing page, answered 404, never reaches a handler.
- **Scanner tools** by their user agent (sqlmap, nikto, nessus and the like).
- **Unexpected HTTP methods** and **oversized** request lines, header sets or parameter counts.

Two deliberate exclusions keep false positives down: fields named like secrets (`password`, `token`, …) are never read
or stored, because a password may legitimately contain any character; and the signed payment-notice bodies are not
inspected. Free-text fields (a support message, a note) are checked only against the unambiguous patterns, not the
query-string heuristics.

The firewall has three modes, set from the console: **off**, **watch only** (log a hit, let the request through) and
**refuse and block** (the default in production). When refusing, a page gets a plain 404 and the API a 403
`REQUEST_REJECTED`, so a prober learns nothing. Repeated hits from one address (default: 5 within 10 minutes) escalate
through `sec.waf_strike` → `sec.auto_block_ip` into a time-boxed `sec.ip_rule` block that expires like any other.

Hits are recorded in `sec.waf_hit` (30 days) with the rule, the location (path, query, header, body, method, size), a
short redacted sample and whether the request was blocked or only logged.

## 3. Host and edge defences against floods

The owner asked specifically for protection from background-command floods such as `ping` that aim to exhaust the
servers. These live below the application, so they hold even for traffic that never becomes a valid HTTP request:

- **Kernel** (`/etc/sysctl.d/99-masslak-hardening.conf`, applied by `deploy/server-setup.sh`): ignore ICMP broadcasts,
  rate-limit ICMP replies (ping floods cannot keep a core busy), SYN cookies with a deep backlog and few synack
  retries (half-open SYN floods), reverse-path filtering and no source routing (spoofed sources), no ICMP redirects.
- **Edge connection rate limit** (`masslak-edge-firewall.service` installs an `iptables` `hashlimit` rule in
  `DOCKER-USER`): new TCP connections to ports 80/443 are capped per source address at a generous ceiling (200/s with a
  short burst) — well above any real browser, below a flood. Per-request abuse above this is the application shield's job.
- **Caddy** (`deploy/Caddyfile`): HTTPS with HSTS preload, the security headers repeated at the edge, a 6 MB body cap,
  unexpected methods refused with 405, obvious probe paths and any `*.map` refused with 404, and dial/response timeouts
  so a slow upstream cannot tie an edge worker up (a slow-read defence).

## 4. The control unit: traffic watch, alerts and the shield level

Every API process counts its traffic in ten-second windows (requests, 4xx/5xx, blocked, rate-limited, firewall hits,
failed sign-ins, and the busiest source addresses) and flushes closed windows to `sec.traffic_sample` (kept 7 days). A
background job (`sec.evaluate_traffic`, run each minute by the notify worker) compares the last full minute against the
thresholds and against the usual load for that time of day, and opens an alert in `sec.traffic_alert` when something is
off:

| Alert | Opens when |
|---|---|
| High traffic (VOLUME) | requests per minute above `alert_rpm` |
| Sudden spike (SPIKE) | requests above `spike_factor` × the usual, over a floor |
| Many errors (ERRORS) | server-error share above `alert_error_pct` |
| Firewall hits (WAF) | firewall hits per minute above `alert_waf_per_min` |
| Sign-in flood (AUTH_FLOOD) | failed sign-ins per minute above `alert_auth_fail_per_min` |

An alert notifies the platform's security staff (`security.traffic_alert`, routed to the `security.console` permission)
by the outbox worker, so the **platform manager — developer and admin — is told about abnormal load**, exactly as asked.
One live alert exists per kind (a partial unique index), so a sustained condition does not flood the inbox; staff
acknowledge and then resolve it from the console.

The **shield level** is the manager's lever to hold traffic until the alert is checked:

- **Normal** — the firewall and limits run as usual.
- **Elevated** — rate limits are tightened (the token budget is multiplied by `elevated_rate_factor`) while a
  suspicious load is investigated. It can be raised by hand, or on its own under heavy load if `auto_elevate` is on,
  for `auto_elevate_min` minutes.
- **Lockdown** — the platform's traffic is **stopped** (503 `SHIELD_LOCKDOWN`, `Retry-After: 60`) except the security
  console, sign-in, payment notices and explicitly allowed addresses — "stop the traffic until it is checked". It is
  held until staff lower it or its optional end time arrives.

Changing the level writes `sec.shield_event` (an append-only history), emits `security.shield_changed` to the security
staff, and is enforced by every API process within a few seconds (each reads `sec.shield_view()` on a short refresh;
the process that made the change applies it at once). Raising or lowering the level, or changing the policy, is a
sensitive operation and requires a recent second factor (step-up, migration 1136).

The console web screen (**Security → Shield**, `frontend/src/pages/security/Shield.tsx`) shows the level with its
controls, the last hour of traffic as a per-minute chart, the live alerts, the recent firewall hits, the busiest
addresses of the last ten minutes, the one-session rule per portal, and the level history. It refreshes on its own
every twenty seconds.

## 5. One session per user (no double sign-in)

To protect a passenger's wallet and rights and to shut out illegitimate concurrent access, each portal has a session
rule in `sec.shield_state.session_policy`: **one session** or **several**. Where a portal keeps one session, a new
sign-in revokes the user's other sessions with reason `replaced by a new sign-in`; the next request on the old session
gets 401 `SESSION_REPLACED` and a clear message, and an `account.signed_in_elsewhere` notice goes to the user. Passenger
and staff portals default to one session in production. Demo and test databases use several sessions so shared accounts
and shared test-runner addresses do not trip the rule.

## 6. Protecting the browser source

The shipped web bundle carries **no source maps** (`frontend/vite.config.ts`, `sourcemap: false`), so the browser holds
only minified code — no original file names, module layout or developer comments. As a second layer, the edge and the
firewall both refuse any `*.js.map` request (404 at Caddy, a `probe` hit in the shield), so even a map served by mistake
could not be fetched.

## 7. Where each piece lives

| Piece | Location |
|---|---|
| Database layer (level, policy, alerts, samples, hits, session rule) | `db/schema/1142_shield.sql` |
| Application firewall and traffic counters | `backend/app/shield.py` |
| Enforcement in the request path | `backend/app/middleware.py` |
| Single-session on sign-in | `backend/app/routers/auth.py`, `backend/app/deps.py` |
| Admin API | `backend/app/routers/security.py` (`/api/security/shield…`) |
| Alerts and notices | `backend/app/modules/notify/` |
| Console web screen | `frontend/src/pages/security/Shield.tsx` |
| Host kernel and edge rate limit | `deploy/server-setup.sh` |
| Edge | `deploy/Caddyfile` |
| Browser source | `frontend/vite.config.ts` |
| Tests | `backend/tests/test_shield.py`, shield block in `db/tests/run_tests.sql` |

## 8. Forward plan

These three items the owner placed "later in the plan". They do not change the application code; they are deployment and
assurance steps, each with a clear entry condition.

### 8.1 Deploy to a private Linux server (through a Linux-server specialist)

The platform already ships as a self-contained install for a private Linux server; the specialist follows the existing
runbooks rather than inventing a process:

1. **Provision** an Ubuntu 22.04/24.04 host (sizing in `docs/operations/INFRASTRUCTURE_REQUIREMENTS.md`), on the owner's
   own infrastructure. Disk encryption at rest is a launch condition (`docs/operations/STAGING.md`).
2. **Harden the host** with `deploy/server-setup.sh` — Docker, a firewall that opens only SSH/HTTP/HTTPS, automatic
   security updates, fail2ban, the kernel flood protection and the edge connection rate limit of this shield, and the
   nightly encrypted backup and hourly signed audit archive.
3. **Install** with `deploy/install.sh` against a signed, pinned image (the installer refuses an unsigned image);
   point `MASSLAK_DOMAIN` at the real domain so Caddy obtains a certificate; put the secrets in the key service that
   production requires at boot (`docs/operations/RUNBOOKS.md`).
4. **For scale/availability**, the high-availability layout (two database hosts, etcd, HAProxy, Patroni) and the second
   site are in `docs/operations/HIGH_AVAILABILITY.md` and wired into the installer.
5. **Verify** with `deploy/verify-release.sh`, the `/api/ready` check, and one firing of each launch gate
   (`docs/operations/LAUNCH_GATES.md`): backup/restore drill, antivirus, alerts, audit archive, migration rehearsal,
   capacity.

The repository stays closed; the specialist works from the release package and these runbooks, not from source access.

### 8.2 Build the mobile apps

The passenger and driver (and operator) apps exist as an Expo/React Native project. The build follows the EAS profiles
and device matrix already defined (`docs/operations/`, review P3-5): build the signed binaries on EAS, test across the
device matrix, and submit to the stores under the owner's developer accounts. The apps talk only to the hardened API,
so the shield protects them exactly as it protects the website; advisory classification and the module-type rule
(review P3-5) gate what a build may contain. This step waits on 8.1, so the apps point at the real server.

### 8.3 Verify against breaches and for strength (penetration testing)

The scope and rules of engagement are written in `docs/security/PENETRATION_TEST_SCOPE.md`:

- Run by an **external** firm or independent tester, never the developers, with time-bound access only through the
  permission matrix.
- Run against **staging** with synthetic data, never production or real personal data.
- Covers the web API, partner API, payment notices, the SPA, authentication/session handling (including the new
  single-session rule), authorisation between roles and companies, business-logic abuse, SSRF, and now the shield
  itself: that the firewall cannot be bypassed, that lockdown truly holds, that the flood defences stand up, and that
  no source map or internal detail leaks to the browser.
- **Launch condition:** every critical or high finding is fixed and retested before general launch, or the owner
  accepts it in writing with a reason and a date (launch gate 8).

This closes the loop the owner asked for: build the defences, deploy them on a private server, ship the apps against
them, then have an independent party try to break them before launch.
