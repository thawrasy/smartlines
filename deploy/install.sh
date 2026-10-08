#!/usr/bin/env bash
# One-command installation of Masslak on a fresh Ubuntu 22.04 / 24.04 server, run as root from the repository:
#   sudo ./deploy/install.sh --domain masslak.com --email ops@masslak.com --admin-email admin@masslak.com
# Options:
#   --demo                 test server: demo data, simulated payments, demo accounts (never on a server with real users)
#   --admin-name "Name"    full name of the first administrator (default: Platform Administrator)
#   --skip-server-setup    the server is already prepared (Docker, firewall); used by CI
#   --backup-recipient K   age public key that encrypts the nightly backups (create the pair on another machine with
#                          age-keygen); a production server writes no backup until it has one
#
# Steps: prepares the server (deploy/server-setup.sh), writes deploy/.env with fresh secrets (deploy/init-env.sh),
# builds and starts the stack, waits until the site answers, creates the first platform administrator with a random
# password generated on this server, and prints the sign-in details. The same details are saved in
# deploy/FIRST_LOGIN.txt (mode 600): move them to a password manager, then delete the file.
set -euo pipefail
cd "$(dirname "$0")/.."
domain="" email="" admin_email="" admin_name="Platform Administrator" demo=false setup=true recipient=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) domain="$2"; shift 2 ;;
    --email) email="$2"; shift 2 ;;
    --admin-email) admin_email="$2"; shift 2 ;;
    --admin-name) admin_name="$2"; shift 2 ;;
    --demo) demo=true; shift ;;
    --skip-server-setup) setup=false; shift ;;
    --backup-recipient) recipient="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$domain" ] && [ -n "$admin_email" ] || {
  echo "usage: $0 --domain <domain> --email <certificate notices address> --admin-email <first administrator> [--demo]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

step() { printf '\n==> %s\n' "$*"; }

if [ "$setup" = true ]; then
  step "Preparing the server: Docker, firewall (22, 80, 443), fail2ban, automatic security updates"
  ./deploy/server-setup.sh
fi

if [ -e deploy/.env ]; then
  step "deploy/.env exists: keeping its secrets"
else
  step "Writing deploy/.env with fresh random secrets"
  args=(--domain "$domain")
  [ -n "$email" ] && args+=(--email "$email")
  [ "$demo" = true ] && args+=(--demo)
  [ -n "$recipient" ] && args+=(--backup-recipient "$recipient")
  ./deploy/init-env.sh "${args[@]}"
fi

step "Building and starting the stack (first build takes a few minutes)"
docker compose --env-file deploy/.env up -d --build

step "Waiting for the application"
for i in $(seq 1 90); do
  if docker compose --env-file deploy/.env exec -T app python -c \
      "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/api/health').status == 200 else 1)" 2>/dev/null; then
    break
  fi
  [ "$i" = 90 ] && { docker compose --env-file deploy/.env logs --tail 80 migrate app; echo "the application did not start" >&2; exit 1; }
  sleep 4
done

step "Creating the first platform administrator"
admin_password="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
pg_password="$(grep '^POSTGRES_PASSWORD=' deploy/.env | cut -d= -f2-)"
created="$(docker compose --env-file deploy/.env run --rm -T \
  -e MASSLAK_OWNER_URL="postgresql://postgres:${pg_password}@db/masslak" -e MASSLAK_ADMIN_PASSWORD="$admin_password" \
  migrate python /app/backend/scripts/create_admin.py "$admin_email" "$admin_name")"
echo "$created"
case "$created" in *"already exists"*) admin_password="(unchanged: the account existed before this run)" ;; esac

url="https://$domain"
step "Waiting for the site to answer over HTTPS (certificate and proxy health check)"
for i in $(seq 1 60); do
  curl -fsSk --resolve "$domain:443:127.0.0.1" "$url/api/health" >/dev/null 2>&1 && break
  [ "$i" = 60 ] && echo "warning: $url does not answer yet; check DNS and: docker compose --env-file deploy/.env logs caddy" >&2
  sleep 3
done
umask 077
cat > deploy/FIRST_LOGIN.txt <<EOF
Masslak installation, $(date -u '+%Y-%m-%d %H:%M UTC')

Site:                 $url
Administration:       $url/login?portal=PLATFORM
Administrator e-mail: $admin_email
Password:             $admin_password

At the first sign-in the platform asks the administrator to enrol a second factor (authenticator app);
keep the recovery codes it shows. Change the password from Account > Security.

Server secrets:       deploy/.env (mode 600). Copy its keys section to a password manager now: without
                      those keys, encrypted identity numbers and documents cannot be read, even from a backup.
Backups:              nightly at 02:15 to /var/backups/masslak (deploy/backup.sh)

Move these details to a password manager, then delete this file:  shred -u deploy/FIRST_LOGIN.txt
EOF
step "Done"
cat deploy/FIRST_LOGIN.txt
if ! grep -q '^MASSLAK_BACKUP_AGE_RECIPIENT=age1' deploy/.env && ! grep -q '^MASSLAK_SANDBOX=true' deploy/.env; then
  echo "ACTION NEEDED: backups are refused until MASSLAK_BACKUP_AGE_RECIPIENT holds an age public key (deploy/README.md, section 4)." >&2
fi
[ "$demo" = true ] && echo "Demo accounts (password Masslak-Demo-2026) are listed in deploy/README.md."
