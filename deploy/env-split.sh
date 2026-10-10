#!/usr/bin/env bash
# One environment file per container, written from deploy/.env (reviews of October 2026, H-06).
#   ./deploy/env-split.sh            (deploy/install.sh, update.sh and restore.sh run it; run it after editing deploy/.env)
#
# deploy/.env stays the operator's single file on the host (root only, mode 600). The containers no longer receive all
# of it: each gets deploy/env/<service>.env with what it needs.
#   app, worker  everything but the owner's and the infrastructure's secrets: the database owner's password, the
#                replication, warehouse and telemetry-owner passwords, the database login passwords (the connection
#                URLs compose writes already hold them), the backup and pgBackRest settings. On a production server
#                also no data key: the API and the worker open wrapped keys with the key service (MASSLAK_KMS_PROVIDER)
#   migrate      everything but the backup and pgBackRest settings (it builds the schema as the owner and wraps the data
#                keys with the key service the first time)
#   db           the owner's login and pgBackRest's repository (production profile)
# Empty values are left out, so a setting someone blanked is unset rather than empty.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "deploy/.env is missing: run deploy/init-env.sh" >&2; exit 1; }
umask 077
mkdir -p env
chmod 0700 env
production=false
grep -q '^MASSLAK_ENVIRONMENT=production$' .env && production=true

infra='^(PGBACKREST_[A-Z0-9_]*|MASSLAK_BACKUP_[A-Z0-9_]*|COMPOSE_[A-Z_]*|MASSLAK_COMPOSE_EXTRA|MASSLAK_IMAGE_TAG|MASSLAK_PREVIOUS_IMAGE_TAG)='
owner='^(POSTGRES_PASSWORD|MASSLAK_API_PASSWORD|MASSLAK_AUDIT_PASSWORD|MASSLAK_REPLICATION_PASSWORD|MASSLAK_CDC_PASSWORD|MASSLAK_DW_PASSWORD|MASSLAK_DW_ANALYST_PASSWORD|MASSLAK_TELEMETRY_OWNER_PASSWORD|MASSLAK_TELEMETRY_PASSWORD|MASSLAK_TELEMETRY_UPKEEP_PASSWORD)='
keys='^(MASSLAK_FIELD_KEYS|MASSLAK_BIDX_KEY|MASSLAK_KEK)='
settings() { grep -E '^[A-Z][A-Z0-9_]*=.' .env || true; }      # KEY=value lines with a value, comments dropped

write() {                                     # service, then the filter command
  local name="$1"; shift
  "$@" > "env/$name.env.tmp"
  chmod 0600 "env/$name.env.tmp"
  mv "env/$name.env.tmp" "env/$name.env"
}
runtime() {
  if [ "$production" = true ]; then settings | grep -Ev "$infra" | grep -Ev "$owner" | grep -Ev "$keys" || true
  else settings | grep -Ev "$infra" | grep -Ev "$owner" || true; fi
}
write app runtime
write worker runtime
write migrate sh -c "grep -E '^[A-Z][A-Z0-9_]*=.' .env | grep -Ev '$infra' || true"
write db sh -c "grep -E '^(POSTGRES_DB|POSTGRES_USER|POSTGRES_PASSWORD|PGBACKREST_[A-Z0-9_]*|MASSLAK_WAREHOUSE_ADDRESS)=.' .env || true"
echo "wrote deploy/env/{app,worker,migrate,db}.env from deploy/.env$([ "$production" = true ] && echo ' (production: no data keys for the API and the worker)')"
