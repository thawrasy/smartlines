# Deploying Masslak

One image contains the API (FastAPI), the built web interface and the database scripts. Docker Compose runs
PostgreSQL 16, a one-shot migration, the application and Caddy (automatic HTTPS).

## Requirements

- A Linux server with Docker Engine and the Compose plugin (2 vCPU and 4 GB RAM are enough for a test server)
- Ports 80 and 443 open, and a DNS record pointing the domain to the server

## First start

```sh
git clone <repository> masslak && cd masslak
cp deploy/.env.example deploy/.env
# fill in the passwords and the signing secret, e.g. with: openssl rand -base64 36
nano deploy/.env
docker compose --env-file deploy/.env up -d --build
docker compose --env-file deploy/.env logs -f migrate app
```

The `migrate` service builds the schema on an empty database, creates the `masslak_api` and `masslak_audit`
login roles, and exits. The application starts after it succeeds. The site is then served at
`https://<MASSLAK_DOMAIN>`.

### Test server with demo data

Set `MASSLAK_SANDBOX=true` and `MASSLAK_SEED_DEMO=true` in `deploy/.env` before the first start. This loads
seven central stations, a demo carrier with three vehicles and drivers, and four routes with a week of trips.
It also creates the accounts below. They share the password `Masslak-Demo-2026`, which a demo build shows on
the sign-in page.

| Account | Portal |
|---|---|
| passenger@masslak.test (wallet 500,000 SYP) | Passenger |
| owner@carrier.test | Carrier |
| driver@carrier.test, driver2@carrier.test, driver3@carrier.test | Driver |
| admin@masslak.test (administration, security, finance) | Platform |
| regulator@masslak.test (read-only dashboard) | Platform |

Sandbox mode simulates the payment gateway for wallet top-ups. Never enable either option in production.

### Production: first administrator

```sh
docker compose --env-file deploy/.env run --rm \
  -e MASSLAK_OWNER_URL=postgresql://postgres:<POSTGRES_PASSWORD>@db/masslak \
  migrate python /app/backend/scripts/create_admin.py admin@example.gov "Full Name"
```

Create further staff, carriers and stations from the administration portal.

## Security notes

- The API connects as `masslak_api`, which row-level security restricts. The security console reads the logs
  through `masslak_audit`. Only the migration step uses the PostgreSQL superuser.
- The database network is internal. Only Caddy publishes ports.
- `MASSLAK_TRUSTED_PROXIES` is the Caddy subnet. IP rules, automatic blocking and the logs all use the client
  address. The app takes that address from `X-Forwarded-For` only when the request comes from this subnet.
  It reads the header from the right, so a client cannot choose its own address.
- `MASSLAK_SIGNING_SECRET` signs ticket QR codes and verification links. Changing it invalidates every one
  already issued.
- Back up the database, for example:
  `docker compose exec db pg_dump -U postgres -Fc masslak > masslak.dump`.

## Updating

```sh
git pull
docker compose --env-file deploy/.env up -d --build
```

Schema changes made after the first start ship as numbered files in `db/schema`. For now, apply each new file
with `psql` and record it in `sys.schema_migration`. An automatic upgrade step comes with the next release.

## Local development without Docker

```sh
./db/build.sh masslak_dev        # PostgreSQL 16 with the contrib extensions
psql -d masslak_dev -v api_password=devapi -v audit_password=devaudit -f db/create_login_roles.sql
MASSLAK_OWNER_URL=postgresql:///masslak_dev python3 backend/scripts/seed_demo.py
cd backend && pip install -r requirements-dev.txt
MASSLAK_DATABASE_URL=postgresql://masslak_api:devapi@localhost/masslak_dev \
MASSLAK_AUDIT_DATABASE_URL=postgresql://masslak_audit:devaudit@localhost/masslak_dev \
MASSLAK_SANDBOX=true MASSLAK_COOKIE_SECURE=false uvicorn app.main:app --port 8077
cd ../frontend && npm install && npm run dev   # http://localhost:5173, /api is proxied to 8077
```

To run the tests, go to `backend`:

- Unit tests: `pytest tests/test_client_ip.py`
- End-to-end tests, with the API running on demo data:
  `MASSLAK_TEST_URL=http://localhost:8077 MASSLAK_OWNER_URL=postgresql:///masslak_dev pytest`
