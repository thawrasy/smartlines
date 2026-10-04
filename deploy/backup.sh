#!/usr/bin/env bash
# Nightly backup: database (pg_dump custom format) and the encrypted document store, with SHA-256 checksums.
# Run from cron as root on the server, e.g.:  15 2 * * *  /opt/masslak/deploy/backup.sh >> /var/log/masslak-backup.log 2>&1
#
# Identity numbers, MFA secrets and documents are already encrypted with keys that are NOT in the backup. The rest
# (names, bookings, ledger) is personal data: if MASSLAK_BACKUP_AGE_RECIPIENT is set (an age public key), each file
# is encrypted with age before it is written. Copy the backup directory off the server (another site or bucket).
set -euo pipefail
cd "$(dirname "$0")/.."
# deploy/.env is KEY=VALUE data, not shell code (values may hold <, spaces or $): export each line as is
while IFS= read -r line; do case "$line" in ''|\#*) ;; *) export "$line" ;; esac; done < deploy/.env
dir="${MASSLAK_BACKUP_DIR:-/var/backups/masslak}/$(date -u +%Y%m%dT%H%M%SZ)"
keep="${MASSLAK_BACKUP_KEEP_DAYS:-14}"
compose() { docker compose --env-file deploy/.env "$@"; }
seal() {                                   # stdin -> file, encrypted with age when a recipient is configured
  if [ -n "${MASSLAK_BACKUP_AGE_RECIPIENT:-}" ]; then age -r "$MASSLAK_BACKUP_AGE_RECIPIENT" > "$1.age"; else cat > "$1"; fi
}
umask 077
mkdir -p "$dir"
compose exec -T db pg_dump -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-masslak}" -Fc | seal "$dir/database.dump"
compose exec -T app tar -C /data -cz files | seal "$dir/files.tar.gz"
(cd "$dir" && sha256sum ./* > SHA256SUMS)
echo "$(date -u +%FT%TZ) backup written to $dir ($(du -sh "$dir" | cut -f1))"
find "$(dirname "$dir")" -mindepth 1 -maxdepth 1 -type d -mtime +"$keep" -print -exec rm -rf {} +
