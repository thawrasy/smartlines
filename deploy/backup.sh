#!/usr/bin/env bash
# Nightly backup: database (pg_dump custom format) and the encrypted document store when it is the volume
# (MASSLAK_FILES_BACKEND=local; an object store keeps its own versions), with SHA-256 checksums.
# Run from cron as root on the server, e.g.:  15 2 * * *  /opt/masslak/deploy/backup.sh >> /var/log/masslak-backup.log 2>&1
#
# Identity numbers, MFA secrets and documents are already encrypted with keys that are NOT in the backup. The rest
# (names, bookings, ledger) is personal data, so each file is encrypted with age (MASSLAK_BACKUP_AGE_RECIPIENT, an age
# public key whose private key is kept off the server) before it is written. A production server
# (MASSLAK_SANDBOX=false) refuses to write a backup without it (review of October 2026, stage A4); only a sandbox
# or demo server may keep plain backups.
#
# Each backup is then copied off the server (review of release 1.47.0, R-41): a server lost with its disks must not take
# its backups with it. MASSLAK_BACKUP_OFFSITE names the destination for rclone: a configured remote and path such as
# "offsite:masslak-backups" (S3, SFTP, another site's storage; rclone config on this server), or a mounted path. The
# copy is checked file by file against the checksums. Both copies are recorded in the database (sys.backup_run) and
# the monitoring alerts when either is older than a day (BackupStale, BackupOffsiteStale).
# Exit status: 0 both copies written, 3 the local copy is written but the off-site copy is not (not configured on a
# production server, or failed), anything else the backup failed.
set -euo pipefail
cd "$(dirname "$0")/.."
# deploy/.env is KEY=VALUE data, not shell code (values may hold <, spaces or $): export each line as is
while IFS= read -r line; do case "$line" in ''|\#*) ;; *) export "$line" ;; esac; done < deploy/.env
dir="${MASSLAK_BACKUP_DIR:-/var/backups/masslak}/$(date -u +%Y%m%dT%H%M%SZ)"
keep="${MASSLAK_BACKUP_KEEP_DAYS:-14}"
compose() { docker compose --env-file deploy/.env "$@"; }
if [ -n "${MASSLAK_BACKUP_AGE_RECIPIENT:-}" ]; then
  command -v age >/dev/null || { echo "backup refused: age is not installed (apt-get install age)" >&2; exit 2; }
  case "$MASSLAK_BACKUP_AGE_RECIPIENT" in age1*) ;; *)
    echo "backup refused: MASSLAK_BACKUP_AGE_RECIPIENT is not an age public key (age1...)" >&2; exit 2 ;; esac
elif [ "${MASSLAK_SANDBOX:-false}" != true ]; then
  echo "backup refused: a production server writes encrypted backups only. Create a key pair on another machine" \
       "(age-keygen -o masslak-backup.key) and put its public key in MASSLAK_BACKUP_AGE_RECIPIENT in deploy/.env." >&2
  exit 2
fi
seal() {                                   # stdin -> file, encrypted with age when a recipient is configured
  if [ -n "${MASSLAK_BACKUP_AGE_RECIPIENT:-}" ]; then age -r "$MASSLAK_BACKUP_AGE_RECIPIENT" > "$1.age"; else cat > "$1"; fi
}
umask 077
mkdir -p "$dir"
compose exec -T db pg_dump -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-masslak}" -Fc | seal "$dir/database.dump"
if [ "${MASSLAK_FILES_BACKEND:-local}" = s3 ]; then
  # files live in the object store: versioning and replication (or object lock) on the bucket keep them, not this
  # backup (docs/operations/RUNBOOKS.md, section 24). The note says where they are, for whoever restores.
  echo "files in s3: ${MASSLAK_FILES_S3_ENDPOINT:-} bucket ${MASSLAK_FILES_S3_BUCKET:-} prefix ${MASSLAK_FILES_S3_PREFIX:-}" > "$dir/FILES_IN_OBJECT_STORE"
else
  compose exec -T app tar -C /data -cz files | seal "$dir/files.tar.gz"
fi
(cd "$dir" && sha256sum ./* > SHA256SUMS)
echo "$(date -u +%FT%TZ) backup written to $dir ($(du -sh "$dir" | cut -f1))"
record() {                                 # copy, ok, detail: kept in the database for the monitoring (1076)
  compose exec -T db psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-masslak}" -qAt -v ON_ERROR_STOP=1 \
    -v copy="$1" -v ok="$2" -v detail="$3" -v bytes="$(du -sb "$dir" | cut -f1)" \
    <<< "SELECT sys.record_backup(:'copy', :'ok'::boolean, :'detail', :'bytes'::bigint)" >/dev/null \
    || echo "could not record the $1 backup in the database" >&2
}
record LOCAL true "$dir"
find "$(dirname "$dir")" -mindepth 1 -maxdepth 1 -type d -mtime +"$keep" -print -exec rm -rf {} +

offsite="${MASSLAK_BACKUP_OFFSITE:-}"
if [ -z "$offsite" ]; then
  if [ "${MASSLAK_SANDBOX:-false}" = true ]; then exit 0; fi
  record OFFSITE false "MASSLAK_BACKUP_OFFSITE is not set"
  echo "backup kept on this server only: set MASSLAK_BACKUP_OFFSITE in deploy/.env (deploy/README.md, section 4)" >&2
  exit 3
fi
command -v rclone >/dev/null || { record OFFSITE false "rclone is not installed"; echo "rclone is not installed (apt-get install rclone)" >&2; exit 3; }
target="${offsite%/}/$(basename "$dir")"
if rclone copy "$dir" "$target" --immutable --retries 5 --low-level-retries 10 && rclone check "$dir" "$target" --one-way; then
  record OFFSITE true "$target"
  echo "$(date -u +%FT%TZ) copied off the server to $target"
  # the off-site copies follow the same retention, unless the destination keeps them itself (object lock, versions)
  if [ "${MASSLAK_BACKUP_OFFSITE_PRUNE:-true}" = true ]; then
    rclone delete "${offsite%/}" --min-age "${keep}d" --rmdirs >/dev/null 2>&1 || true
  fi
else
  record OFFSITE false "copy to $target failed"
  echo "the off-site copy to $target failed; the local backup is in $dir" >&2
  exit 3
fi
