# Deploying Masslak

One image contains the API (FastAPI), the built web interface and the database scripts. Docker Compose runs:

| Service | Role | Reachable from |
|---|---|---|
| `caddy` | HTTPS front, automatic certificates, HTTP/3 | the internet (ports 80, 443) |
| `app` | API and web interface | Caddy only |
| `worker` | sends e-mail and SMS from the notification outbox | nothing (outbound only) |
| `migrate` | one-shot: builds or upgrades the schema, sets login roles, then exits | nothing |
| `db` | PostgreSQL 16 | internal network only |

CI starts this exact stack on every push and checks HTTPS, sign-in, search, that only Caddy is reachable, and a
full backup and restore (`.github/workflows/ci.yml`, job `stack`).

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

## 3. Updating

```sh
cd /opt/masslak && sudo ./deploy/update.sh
```

The script backs up first, pulls the code, rebuilds and restarts. The `migrate` service applies new schema files
(`db/upgrade.sh`, recorded in `sys.schema_file`) before the new API starts.

## 4. Backups

`server-setup.sh` schedules `deploy/backup.sh` every night at 02:15 (`/etc/cron.d/masslak-backup`). Each backup
holds a `pg_dump` of the database and the document store, with SHA-256 checksums, kept for
`MASSLAK_BACKUP_KEEP_DAYS` days in `MASSLAK_BACKUP_DIR`.

- To encrypt backups, install `age`, create a key pair on another machine (`age-keygen -o masslak-backup.key`) and
  put the public key in `MASSLAK_BACKUP_AGE_RECIPIENT`. Keep the private key off the server.
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
  offline ticket credentials. Changing either invalidates everything already issued.
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
