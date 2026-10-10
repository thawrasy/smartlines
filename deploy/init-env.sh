#!/usr/bin/env bash
# Creates deploy/.env from .env.example with fresh random secrets. Never overwrites an existing file.
#   ./deploy/init-env.sh --domain masslak.com --email ops@masslak.com            production
#   ./deploy/init-env.sh --domain test.masslak.com --email ops@masslak.com --demo  test server with demo data
#   ./deploy/init-env.sh --domain localhost --demo                                    local trial
# Production also takes --backup-recipient <age public key> (deploy/backup.sh writes only encrypted backups there).
set -euo pipefail
cd "$(dirname "$0")"
domain="" email="" demo=false locale=ar recipient=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) domain="$2"; shift 2 ;;
    --email) email="$2"; shift 2 ;;
    --demo) demo=true; shift ;;
    --locale) locale="$2"; shift 2 ;;
    --backup-recipient) recipient="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$domain" ] || { echo "usage: $0 --domain <domain> [--email <address>] [--demo] [--locale ar|en]" >&2; exit 2; }
[ "$domain" = localhost ] || [ -n "$email" ] || { echo "--email is required for a public domain (certificate notices)" >&2; exit 2; }
[ -e .env ] && { echo "deploy/.env already exists; not overwritten" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }
case "$recipient" in ''|age1*) ;; *) echo "--backup-recipient must be an age public key (age1...)" >&2; exit 2 ;; esac

key() { openssl rand -base64 32; }          # exactly 32 bytes, base64
pass() { openssl rand -hex 24; }            # URL-safe: passwords go inside connection strings

umask 077
sed -e "s|^MASSLAK_DOMAIN=.*|MASSLAK_DOMAIN=$domain|" \
    -e "s|^MASSLAK_ACME_EMAIL=.*|MASSLAK_ACME_EMAIL=${email:-admin@localhost}|" \
    -e "s|^MASSLAK_DEFAULT_LOCALE=.*|MASSLAK_DEFAULT_LOCALE=$locale|" \
    -e "s|^MASSLAK_SANDBOX=.*|MASSLAK_SANDBOX=$demo|" \
    -e "s|^MASSLAK_SEED_DEMO=.*|MASSLAK_SEED_DEMO=$demo|" \
    -e "s|^MASSLAK_ENVIRONMENT=.*|MASSLAK_ENVIRONMENT=$([ "$demo" = true ] && echo development || echo production)|" \
    -e "s|^MASSLAK_ZERO_DATA_LOSS=.*|MASSLAK_ZERO_DATA_LOSS=$([ "$demo" = true ] && echo off || echo on)|" \
    -e "s|^MASSLAK_NOTIFY_EMAIL=.*|MASSLAK_NOTIFY_EMAIL=$([ "$demo" = true ] && echo log || echo off)|" \
    -e "s|^MASSLAK_NOTIFY_SMS=.*|MASSLAK_NOTIFY_SMS=$([ "$demo" = true ] && echo log || echo off)|" \
    -e "s|^MASSLAK_NOTIFY_WHATSAPP=.*|MASSLAK_NOTIFY_WHATSAPP=$([ "$demo" = true ] && echo log || echo off)|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(pass)|" \
    -e "s|^MASSLAK_API_PASSWORD=.*|MASSLAK_API_PASSWORD=$(pass)|" \
    -e "s|^MASSLAK_AUDIT_PASSWORD=.*|MASSLAK_AUDIT_PASSWORD=$(pass)|" \
    -e "s|^MASSLAK_REPLICATION_PASSWORD=.*|MASSLAK_REPLICATION_PASSWORD=$(pass)|" \
    -e "s|^MASSLAK_SIGNING_SECRET=.*|MASSLAK_SIGNING_SECRET=$(openssl rand -base64 48 | tr -d '\n')|" \
    -e "s|^MASSLAK_FIELD_KEYS=.*|MASSLAK_FIELD_KEYS=$([ "$demo" = true ] && echo "kms://masslak/field/restricted/v1=$(key),kms://masslak/field/confidential/v1=$(key)")|" \
    -e "s|^MASSLAK_BIDX_KEY=.*|MASSLAK_BIDX_KEY=$([ "$demo" = true ] && key)|" \
    -e "s|^MASSLAK_TICKET_SIGNING_KEY=.*|MASSLAK_TICKET_SIGNING_KEY=$(key)|" \
    -e "s|^MASSLAK_QR_KEYS=.*|MASSLAK_QR_KEYS=q$(date -u +%Y%m):$(key)|" \
    -e "s|^MASSLAK_DOCUMENT_KEYS=.*|MASSLAK_DOCUMENT_KEYS=d$(date -u +%Y%m):$(key)|" \
    -e "s|^MASSLAK_BACKUP_AGE_RECIPIENT=.*|MASSLAK_BACKUP_AGE_RECIPIENT=$recipient|" \
    .env.example > .env
chmod 600 .env
echo "created deploy/.env (mode 600) for $domain$([ "$demo" = true ] && echo ', demo mode')"
echo "Copy the keys section to your password manager or secret store now: without it, encrypted data cannot be read."
# a production server's data keys are made by the key service at the first migration and kept only wrapped (H-06)
[ "$demo" = true ] || echo "Production: set MASSLAK_KMS_PROVIDER=vault, MASSLAK_VAULT_ADDR and MASSLAK_VAULT_TOKEN, the pgBackRest repository (PGBACKREST_REPO1_*), MASSLAK_BACKUP_OFFSITE and the alert receivers before installing (docs/operations/PRODUCTION_PROFILE.md)."
[ "$demo" = true ] || echo "E-mail, SMS and WhatsApp are off until you set MASSLAK_NOTIFY_EMAIL=smtp, MASSLAK_NOTIFY_SMS=http and MASSLAK_NOTIFY_WHATSAPP=cloud with their gateways."
