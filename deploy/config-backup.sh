#!/usr/bin/env bash
# The server's own configuration, kept apart from the data backup (wave 7, owner's notes 20-32): what a new server needs
# to take this one's place besides the database and the files. Run as root from cron weekly and after every change:
#   20 3 * * 0  root /opt/masslak/deploy/config-backup.sh >> /var/log/masslak-config-backup.log 2>&1
#
# The archive holds deploy/.env, the per-service environment files, deploy/production/{secrets,tls,targets} and its
# local settings, the host's hardening (sysctl, the edge firewall unit and script, ufw rules, fail2ban jails, Docker's
# daemon settings), the cron entries of the platform and the list of installed packages. These are secrets: the archive
# is always encrypted with age (MASSLAK_BACKUP_AGE_RECIPIENT, the same public key as the data backup, whose private key
# is kept off the server) and the script refuses to write it otherwise. It is copied off the server with rclone to
# MASSLAK_BACKUP_OFFSITE/config, like the data backup. Restoring it: docs/operations/SERVER_CONFIG_RESTORE.md.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "run as root: the archive reads the host's settings" >&2; exit 1; }
while IFS= read -r line; do case "$line" in ''|\#*) ;; *) export "$line" ;; esac; done < deploy/.env

recipient="${MASSLAK_BACKUP_AGE_RECIPIENT:-}"
case "$recipient" in age1*) ;; *)
  echo "config backup refused: MASSLAK_BACKUP_AGE_RECIPIENT must hold an age public key (age1...): the archive holds secrets" >&2
  exit 2 ;; esac
command -v age >/dev/null || { echo "config backup refused: age is not installed (apt-get install age)" >&2; exit 2; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dir="${MASSLAK_BACKUP_DIR:-/var/backups/masslak}/config"
umask 077
mkdir -p "$dir"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

app="$(pwd)"
paths=()
for p in deploy/.env deploy/env deploy/production/secrets deploy/production/tls deploy/production/targets \
         deploy/production/ha/bundles deploy/Caddyfile.local docker-compose.override.yml; do
  [ -e "$app/$p" ] && paths+=("$app/$p")
done
for p in /etc/sysctl.d/99-masslak-hardening.conf /usr/local/sbin/masslak-edge-firewall.sh \
         /etc/systemd/system/masslak-edge-firewall.service /etc/docker/daemon.json /etc/ufw /etc/fail2ban/jail.local \
         /etc/fail2ban/jail.d /etc/cron.d/masslak-backup /etc/cron.d/masslak-audit-archive /etc/cron.d/masslak-config-backup \
         /root/.config/rclone/rclone.conf; do
  [ -e "$p" ] && paths+=("$p")
done
{
  echo "host: $(hostname)"; echo "taken: $stamp"; echo "application: $app"
  echo "release: $(git -C "$app" describe --tags --always 2>/dev/null || echo unknown)"
  . /etc/os-release && echo "os: $PRETTY_NAME"
  echo "docker: $(docker --version 2>/dev/null || echo none)"
} > "$work/MANIFEST"
dpkg-query -W -f='${Package} ${Version}\n' > "$work/packages.txt" 2>/dev/null || true
ufw status verbose > "$work/ufw-status.txt" 2>/dev/null || true

out="$dir/masslak-config-$stamp.tar.gz.age"
tar -czf - -C / "${paths[@]#/}" -C "$work" MANIFEST packages.txt ufw-status.txt 2>/dev/null | age -r "$recipient" > "$out"
sha256sum "$out" > "$out.sha256"
echo "server configuration saved to $out ($(du -h "$out" | cut -f1))"

# keep 26 weekly archives on the server
ls -1t "$dir"/masslak-config-*.tar.gz.age 2>/dev/null | tail -n +27 | while read -r old; do rm -f "$old" "$old.sha256"; done

offsite="${MASSLAK_BACKUP_OFFSITE:-}"
if [ -z "$offsite" ]; then
  echo "kept on this server only: set MASSLAK_BACKUP_OFFSITE in deploy/.env" >&2
  exit 3
fi
command -v rclone >/dev/null || { echo "rclone is not installed (apt-get install rclone)" >&2; exit 3; }
if rclone copy "$out" "${offsite%/}/config" --immutable --retries 5 && rclone copy "$out.sha256" "${offsite%/}/config" --immutable; then
  echo "copied to ${offsite%/}/config"
else
  echo "the off-site copy failed: the archive is on this server only" >&2
  exit 3
fi
