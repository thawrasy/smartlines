#!/usr/bin/env bash
# Hourly: export the audit logs to the signed archive, copy it to storage with object lock, and record how far the
# archive reaches so the daily upkeep may drop old audit months (docs/operations/RUNBOOKS.md, section 7). The export was
# written in the runbook only and ran nowhere unless someone set it up (third-party follow-up, October 2026);
# deploy/server-setup.sh now schedules this script:
#   5 * * * *  root /opt/masslak/deploy/audit-archive.sh >> /var/log/masslak-audit-archive.log 2>&1
#
# Settings in deploy/.env:
#   MASSLAK_AUDIT_ARCHIVE_DIR       the archive on this server (default /var/lib/masslak/audit-archive)
#   MASSLAK_AUDIT_SIGNING_KEY_FILE  path of the Ed25519 private key from the key service; required outside the sandbox
#   MASSLAK_AUDIT_VERIFY_KEY_FILE   path of its public key: the chain and signatures are checked before recording
#   MASSLAK_AUDIT_SYNC_COMMAND      copies the archive to the locked bucket; {dir} stands for the archive, e.g.
#                                   aws s3 sync {dir} s3://masslak-audit-archive/ --no-progress
# Without a sync command the export still runs, but nothing is recorded: the database keeps every audit month online
# and the alert AuditArchiveBehind fires, because the archive is not off the server yet.
set -euo pipefail
cd "$(dirname "$0")/.."
# deploy/.env is KEY=VALUE data, not shell code: export each line as is
while IFS= read -r line; do case "$line" in ''|\#*) ;; *) export "$line" ;; esac; done < deploy/.env
compose() { docker compose --env-file deploy/.env "$@"; }

dir="${MASSLAK_AUDIT_ARCHIVE_DIR:-/var/lib/masslak/audit-archive}"
key="${MASSLAK_AUDIT_SIGNING_KEY_FILE:-}"
if [ -z "$key" ] && [ "${MASSLAK_SANDBOX:-false}" != true ]; then
  echo "audit archive refused: production signs every manifest; put the private key's path in" \
       "MASSLAK_AUDIT_SIGNING_KEY_FILE (python -m app.tools.audit_export keygen, then the key service)" >&2
  exit 2
fi
[ -z "$key" ] || [ -r "$key" ] || { echo "audit archive refused: cannot read $key" >&2; exit 2; }
umask 077
mkdir -p "$dir"

# One-off containers of the application image on the database network, as root inside so they can read the key file
# (mode 600 on this server); they write to the archive directory only.
tool() { compose run --rm --no-deps -T --user 0:0 "$@"; }
signing=()
[ -z "$key" ] || signing=(-v "$key:/run/audit-signing.key:ro" -e MASSLAK_AUDIT_SIGNING_KEY=/run/audit-signing.key)
tool -v "$dir:/archive" "${signing[@]}" app python -m app.tools.audit_export export /archive

if [ -n "${MASSLAK_AUDIT_SYNC_COMMAND:-}" ]; then
  sh -c "${MASSLAK_AUDIT_SYNC_COMMAND//\{dir\}/$dir}"
  verify=()
  if [ -n "${MASSLAK_AUDIT_VERIFY_KEY_FILE:-}" ]; then
    verify=(-v "$MASSLAK_AUDIT_VERIFY_KEY_FILE:/run/audit-verify.pub:ro" -e MASSLAK_AUDIT_VERIFY_KEY=/run/audit-verify.pub)
  fi
  # verifies the chain (and the signatures with the public key), then writes audit.archive_checkpoint
  tool -v "$dir:/archive:ro" "${verify[@]}" app python -m app.tools.audit_export record /archive
else
  echo "$(date -u +%FT%TZ) exported to $dir; not copied off the server (MASSLAK_AUDIT_SYNC_COMMAND unset), nothing recorded"
fi
# the tip of the chain, for the evidence custodian's record outside the platform
tool -v "$dir:/archive:ro" app python -m app.tools.audit_export head /archive
