#!/usr/bin/env bash
# Restores a backup made by backup.sh. Replaces the current database and documents.
#   ./deploy/restore.sh /var/backups/masslak/20261004T021500Z --yes
# Needs the same deploy/.env keys as when the backup was made, or encrypted fields and documents cannot be read.
set -euo pipefail
src="${1:?backup directory}"; [ "${2:-}" = "--yes" ] || { echo "this replaces all current data; re-run with --yes" >&2; exit 2; }
cd "$(dirname "$0")/.."
set -a; . deploy/.env; set +a
compose() { docker compose --env-file deploy/.env "$@"; }
open() {                                   # backup file -> stdout, decrypting with age when needed
  if [ -f "$src/$1.age" ]; then age -d -i "${MASSLAK_BACKUP_AGE_IDENTITY:?set MASSLAK_BACKUP_AGE_IDENTITY to the age key file}" "$src/$1.age"
  else cat "$src/$1"; fi
}
(cd "$src" && sha256sum -c --quiet SHA256SUMS) || { echo "checksum mismatch: backup is damaged" >&2; exit 1; }
db="${POSTGRES_DB:-masslak}" su="${POSTGRES_USER:-postgres}"
compose stop app worker
compose exec -T db psql -U "$su" -d postgres -v ON_ERROR_STOP=1 -q \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid()" \
  -c "DROP DATABASE IF EXISTS \"$db\"" -c "CREATE DATABASE \"$db\""
open database.dump | compose exec -T db pg_restore -U "$su" -d "$db" --no-owner --exit-on-error
open files.tar.gz | compose run --rm -T --no-deps --entrypoint "" -u 0 app sh -c 'rm -rf /data/files/* && tar -C /data -xz && chown -R masslak /data/files'
compose up -d migrate app worker           # migrate re-applies login role passwords and any newer schema files
echo "restored from $src"
