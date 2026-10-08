# Deploying Masslak

One image contains the API (FastAPI), the built web interface and the database scripts. Docker Compose runs:

| Service | Role | Reachable from |
|---|---|---|
| `caddy` | HTTPS front, automatic certificates, HTTP/3 | the internet (ports 80, 443) |
| `app` | API and web interface | Caddy only |
| `worker` | sends e-mail, SMS and webhooks from the outbox, scans uploaded files, keeps the egress allowlist | nothing |
| `egress` | Squid forward proxy: the only way out for `app` and `worker` (HTTPS and mail submission to allowlisted names, never to internal addresses) | `app` and `worker` only |
| `migrate` | one-shot: builds or upgrades the schema, sets login roles, then exits | nothing |
| `db` | PostgreSQL 16 | internal network only |

CI starts this exact stack on every push and checks HTTPS, sign-in, search, that only Caddy is reachable, that the API
and the worker have no route out except the egress proxy, and a full backup and restore (`.github/workflows/ci.yml`,
job `stack`).

**Outbound traffic (audit T3-02).** `app` and `worker` sit on internal networks only. Every call to a payment provider, the
SMS gateway, the SMTP relay or a partner webhook goes through `egress` (`MASSLAK_EGRESS_PROXY`), and the API refuses to start
in production without it.
- **Fixed providers:** add their domains to `deploy/egress/allowlist.txt`, then run
  `docker compose exec egress squid -k reconfigure`.
- **Partner webhooks:** the worker adds their domains by itself.
- **Probe:** `docker compose exec worker bash /app/deploy/egress/selftest.sh egress:3128`.

## 1. Server and domain

- A Linux server, Ubuntu 22.04 or 24.04. A test server needs 2 vCPU, 4 GB RAM and 40 GB disk; size production
  from load tests (start at 4 vCPU and 8 GB).
- A domain, with DNS `A` (and `AAAA` if the server has IPv6) records for `masslak.com` and
  `www.masslak.com` pointing at the server. Set them first: the certificate is issued on first start.

## 2. First start

### One command

On the prepared domain (section 1), as root:

```sh
sudo apt-get update && sudo apt-get install -y git
sudo git clone <repository URL> /opt/masslak && cd /opt/masslak
sudo ./deploy/install.sh --domain masslak.com --email ops@masslak.com --admin-email admin@masslak.com
```

It prepares the server, writes `deploy/.env` with fresh secrets, builds and starts the stack, creates the first
platform administrator with a random password generated on the server, and prints the sign-in details (also saved
in `deploy/FIRST_LOGIN.txt`, mode 600). The administrator enrols a second factor at the first sign-in. Move the
details and the keys section of `deploy/.env` to a password manager, then `shred -u deploy/FIRST_LOGIN.txt`.
Add `--demo` for a test server with demo data. CI runs this installer on every push (job `stack`).

### Step by step

```sh
sudo apt-get update && sudo apt-get install -y git
sudo git clone <repository URL> /opt/masslak && cd /opt/masslak
sudo ./deploy/server-setup.sh                 # Docker, firewall (22/80/443), fail2ban, security updates, nightly backup
sudo ./deploy/init-env.sh --domain masslak.com --email ops@masslak.com
sudo docker compose --env-file deploy/.env up -d --build
sudo docker compose --env-file deploy/.env logs -f migrate app
```

`init-env.sh` writes `deploy/.env` (mode 600) with random passwords and keys. **Copy its keys section to a
password manager or secret store right away.** Without those keys, the encrypted identity numbers, MFA secrets
and documents cannot be read, even from a backup.

The site is then at `https://masslak.com`. Caddy obtains and renews the certificate by itself.

### Test server with demo data

Add `--demo` to `init-env.sh`. This turns on the simulated payment gateway and loads demo stations, a carrier with
vehicles and drivers, four routes with a week of trips, and these accounts. They share the password
`Masslak-Demo-2026`, which a demo build shows on the sign-in page.

| Account | Portal |
|---|---|
| passenger@masslak.test (wallet 500,000 SYP) | Passenger |
| owner@carrier.test | Carrier |
| agency@agency.test | Agency |
| driver@carrier.test, driver2@carrier.test, driver3@carrier.test | Driver |
| admin@masslak.test (administration, security, finance) | Platform |
| finance@masslak.test | Platform (finance) |
| security@masslak.test | Platform (security: approves travel-document exceptions drafted by the administrator) |
| regulator@masslak.test (read-only dashboard) | Platform |

Never use `--demo` on a server with real users.

### Local trial on your own computer

```sh
./deploy/init-env.sh --domain localhost --demo
docker compose --env-file deploy/.env up -d --build
```

Then open `https://localhost` and accept the browser warning (the certificate comes from Caddy's local CA).

### Production: first administrator

```sh
sudo docker compose --env-file deploy/.env run --rm \
  -e MASSLAK_OWNER_URL="postgresql://postgres:$(grep ^POSTGRES_PASSWORD= deploy/.env | cut -d= -f2)@db/masslak" \
  migrate python /app/backend/scripts/create_admin.py admin@example.gov "Full Name"
```

Create further staff, carriers, agencies and stations from the administration portal.

## Search engines

The public landing pages (`/ar`, `/en`, routes under `/ar/bus/...`, cities, services, FAQ) are rendered on the server
with canonical links, Arabic and English alternates and structured data; `/sitemap.xml` lists them all and
`/robots.txt` keeps the private portals out. After the first start:

1. Add the site in Google Search Console and Bing Webmaster Tools (domain property), put the verification tokens in
   `MASSLAK_GOOGLE_SITE_VERIFICATION` and `MASSLAK_BING_SITE_VERIFICATION` in `deploy/.env`, and restart `app`.
2. Submit `https://<domain>/sitemap.xml` in both consoles.
3. Create a Google Business Profile for the company with the same name, address and phone as on the site.
   The contact page shows the values of `MASSLAK_SUPPORT_EMAIL`, `MASSLAK_SUPPORT_PHONE`, `MASSLAK_SUPPORT_WHATSAPP`,
   `MASSLAK_BUSINESS_EMAIL`, `MASSLAK_OFFICE_ADDRESS` and `MASSLAK_SUPPORT_HOURS`; set them before launch. The terms of
   use (`/ar/terms`) and the privacy notice (`/ar/privacy`) are published as version 1.0 drafts and need the company's
   legal review before general launch.

Canonical addresses use `https://$MASSLAK_DOMAIN` (set in `docker-compose.yml`).

## 3. Updating

```sh
cd /opt/masslak && sudo ./deploy/update.sh --sha <commit id approved for release>
```

The script settles the code first, then backs up, rebuilds and restarts. The `migrate` service applies new schema
files (`db/upgrade.sh`, recorded in `sys.schema_file`) before the new API starts.

- It stops, with the running version still serving, when the fetch or pull fails, when the branch has diverged from
  `origin` or has local commits, when tracked files were edited on the server, or when the checked-out commit is not
  the one given with `--sha` (at least 12 characters; `MASSLAK_EXPECTED_SHA` works too).
- It stops when an applied schema file was changed (`db/upgrade.sh`, exit code 3): nothing is applied.
- It ends only when `https://<domain>/api/ready` answers, and appends the deployed commit to `deploy/DEPLOYED`.

`GET /api/health` says only that the process answers (the container health check and Caddy use it). `GET /api/ready`
answers 200 when the database, the applied schema, the audit connection and the reports replica are all in order,
and 503 otherwise; use it for deployment checks, monitoring and any load balancer in front of several API instances.

## 4. Backups

`server-setup.sh` schedules `deploy/backup.sh` every night at 02:15 (`/etc/cron.d/masslak-backup`). Each backup
holds a `pg_dump` of the database and the document store, with SHA-256 checksums, kept for
`MASSLAK_BACKUP_KEEP_DAYS` days in `MASSLAK_BACKUP_DIR`.

- Backups are encrypted with `age` (installed by `server-setup.sh`). Create a key pair on another machine
  (`age-keygen -o masslak-backup.key`) and put the public key (`age1...`) in `MASSLAK_BACKUP_AGE_RECIPIENT`, or pass
  it to `install.sh --backup-recipient`. Keep the private key off the server; a restore needs it
  (`MASSLAK_BACKUP_AGE_IDENTITY`).
- A production server (`MASSLAK_SANDBOX=false`) refuses to write a backup without that key, and `update.sh`, which
  backs up first, stops with it. Only a demo or sandbox server keeps plain backups.
- Copy the backup directory to a second location (another site or an object store) every day.
- Restore, which replaces all current data:
  `sudo ./deploy/restore.sh /var/backups/masslak/<timestamp> --yes`
  It needs the same keys in `deploy/.env` as when the backup was taken.
- Rehearse a restore on a test server at least once a quarter.

## 5. Mobile apps

Build the apps against the production domain and pin its certificate chain. Let's Encrypt changes the server key
on renewal, so pin the CA keys rather than the leaf: ISRG Root X1 as the current pin and ISRG Root X2 as the
backup.

```sh
for c in isrgrootx1 isrg-root-x2; do
  curl -fsS https://letsencrypt.org/certs/$c.pem | openssl x509 -pubkey -noout |
    openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
done
MASSLAK_API_URL=https://masslak.com MASSLAK_API_PINS=<pin1>,<pin2> npx eas build ...
```

## Security notes

- The API connects as `masslak_api`, which row-level security restricts. The security console reads the logs
  through `masslak_audit`. Only the migration step and backups use the PostgreSQL superuser.
- The database network is internal. Only Caddy publishes ports, and the firewall allows only 22, 80 and 443.
- `MASSLAK_TRUSTED_PROXIES` is the Caddy subnet. IP rules, automatic blocking and the logs all use the client
  address. The app takes that address from `X-Forwarded-For` only when the request comes from this subnet. It
  reads the header from the right, so a client cannot choose its own address.
- `MASSLAK_SIGNING_SECRET` signs ticket QR codes and verification links, and `MASSLAK_TICKET_SIGNING_KEY` signs
  offline ticket credentials. Changing either invalidates everything already issued. Outside the sandbox the API
  and the worker refuse to start when the signing secret is missing, a placeholder, shorter than 32 bytes or not
  random, or when the ticket key is missing or not 32 bytes of base64; `init-env.sh` generates both.
- The API's database login has time limits (`db/create_login_roles.sql`): a statement stops after 30 s, a lock is
  waited for at most 5 s, and a transaction idle for 2 minutes is ended. A request that hits one answers
  `503 SERVICE_BUSY` with `Retry-After`.
- `MASSLAK_FIELD_KEYS` and `MASSLAK_BIDX_KEY` encrypt identity numbers, MFA secrets and documents (AES-256-GCM)
  and build their blind indexes. To rotate a field key, register a new key reference in `sec.key_registry`, add
  it to `MASSLAK_FIELD_KEYS` and move the old reference to `DECRYPT_ONLY`; existing rows still decrypt with their
  own key. Never change `MASSLAK_BIDX_KEY` after launch.
- Container logs rotate at 20 MB × 5 files (`/etc/docker/daemon.json`).

## Local development without Docker

```sh
./db/build.sh masslak_dev        # PostgreSQL 16 with the contrib extensions
psql -d masslak_dev -v api_password=devapi -v audit_password=devaudit -f db/create_login_roles.sql
MASSLAK_OWNER_URL=postgresql:///masslak_dev python3 backend/scripts/seed_demo.py
MASSLAK_OWNER_URL=postgresql:///masslak_dev python3 backend/scripts/seed_modules.py   # demo data for every module
cd backend && pip install -r requirements-dev.txt
MASSLAK_DATABASE_URL=postgresql://masslak_api:devapi@localhost/masslak_dev \
MASSLAK_AUDIT_DATABASE_URL=postgresql://masslak_audit:devaudit@localhost/masslak_dev \
MASSLAK_SANDBOX=true MASSLAK_COOKIE_SECURE=false uvicorn app.main:app --port 8077
cd ../frontend && npm install && npm run dev   # http://localhost:5173, /api is proxied to 8077
```

Tests, from `backend`, with the API running on demo data:
`MASSLAK_TEST_URL=http://localhost:8077 MASSLAK_OWNER_URL=postgresql:///masslak_dev pytest`
