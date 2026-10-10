#!/usr/bin/env bash
# Restores a backup made by backup.sh. Replaces the current database and documents.
#   ./deploy/restore.sh /var/backups/masslak/20261004T021500Z --yes
# Needs the same deploy/.env keys as when the backup was made, or encrypted fields and documents cannot be read.
set -euo pipefail
src="${1:?backup directory}"; [ "${2:-}" = "--yes" ] || { echo "this replaces all current data; re-run with --yes" >&2; exit 2; }
cd "$(dirname "$0")/.."
# deploy/.env is KEY=VALUE data, not shell code (values may hold <, spaces or $): export each line as is
while IFS= read -r line; do case "$line" in ''|\#*) ;; *) export "$line" ;; esac; done < deploy/.env
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
if [ -f "$src/FILES_IN_OBJECT_STORE" ]; then      # the files were in the object store, which keeps its own versions
  echo "documents are not in this backup: $(cat "$src/FILES_IN_OBJECT_STORE")"
else
  open files.tar.gz | compose run --rm -T --no-deps --entrypoint "" -u 0 app sh -c 'rm -rf /data/files/* && tar -C /data -xz && chown -R masslak /data/files'
fi
./deploy/env-split.sh                      # each container receives only its part of deploy/.env (H-06)
compose up -d migrate app worker           # migrate re-applies login role passwords and any newer schema files
echo "restored from $src"
# the restored database and the stored files must belong to the same moment (review of release 1.47.0, R-44): every
# file the database refers to is read back, decrypted and compared with its recorded size and hash. With the files in
# an object store, restore the bucket to the database's time first (versioning; RUNBOOKS.md, section 2).
for _ in $(seq 1 60); do
  compose exec -T app python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/api/health').status == 200 else 1)" \
    2>/dev/null && break
  sleep 3
done
if ! compose exec -T app python -m app.tools.files_check ${MASSLAK_RESTORE_CHECK_SAMPLE:+--sample "$MASSLAK_RESTORE_CHECK_SAMPLE"}; then
  echo "the restored database refers to files that are missing or differ: see the report above" >&2
  exit 5
fi
