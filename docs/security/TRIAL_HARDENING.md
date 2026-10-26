# Hardening from the trial server's scans (wave 1 of v1.52.0)

The owner's trial server (October 2026) was scanned from outside by several parties; the reports are kept with the
owner's notes. This file records what the code now does about each finding and where.

| Finding | Change | Where |
|---|---|---|
| `/api/docs` and `/api/openapi.json` open on a sandbox | No server publishes the internal API document unless `MASSLAK_API_DOCS=true`; the sandbox no longer opens it by itself. The partners' document (`/api/v1/openapi.json`) stays published. | `backend/app/main.py`, `backend/app/config.py` |
| `/api/ready` listed its checks to anyone | The public sees `{"ready": true|false}`; the names of the checks only reach callers on the server's own network (loopback and the private ranges Docker uses). | `backend/app/routers/public.py`, `backend/app/readiness.py` |
| `robots.txt` listed the private screens | A production server names only `/api/`; every app screen already answers `X-Robots-Tag: noindex`. A sandbox, development or staging server answers `Disallow: /` and marks every page `noindex, nofollow`. | `backend/app/modules/seo/pages.py`, `backend/app/main.py` |
| No `security.txt` | `/.well-known/security.txt` (RFC 9116): contact (`MASSLAK_SECURITY_CONTACT`, default `mailto:security@masslak.com`), an expiry under a year ahead, languages, canonical address. | `backend/app/modules/seo/pages.py` |
| `traceparent` echoed in every response | The trace stays in the logs, the outbox events and the outbound calls; responses carry `X-Request-Id` only. | `backend/app/middleware.py` |
| `Server: Caddy` on port 80 | Port 80 is an explicit site that only redirects to HTTPS and removes the header; certificate challenges are still answered. | `deploy/Caddyfile` |
| Container logs could fill the disk under a flood | Every container's Docker log is capped (json-file, 5 files of 20 MB). | `docker-compose.yml` |
| Containers ran with default privileges | The API and the worker run read-only with a 64 MB private `/tmp`, no Linux capabilities and `no-new-privileges`; PgBouncer, the egress proxy and Caddy get `no-new-privileges`. The one-off restore container asks back the three capabilities it needs. | `docker-compose.yml`, `deploy/restore.sh` |

Server-side steps (SSH keys only, no root login, SSH banner, closing the document on the trial server) are done with
the owner present (wave 9 of the plan, `docs/security/SSH_HARDENING.md`, `deploy/ssh-harden.sh`).
