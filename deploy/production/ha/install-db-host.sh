#!/usr/bin/env bash
# Installs or updates a database host of the production layout with two (reviews of October 2026, H-01;
# docs/operations/HIGH_AVAILABILITY.md). Run as root on the database host, from the same signed release archive as the
# application host, with the host's bundle that deploy/production/init.sh wrote on the application host
# (deploy/production/ha/bundles/db1.tar.gz or db2.tar.gz, copied over SSH; it holds secrets: delete it once installed):
#
#   sudo ./deploy/production/ha/install-db-host.sh /root/db1.tar.gz [/etc/masslak/db-host]
#
# It unpacks the bundle into the host's directory (root only), checks and pulls the signed database image the release
# names (deploy/images.sh: cosign, by digest, never built here), starts etcd and Patroni (db-host.yml), waits until
# the member runs, and schedules pgBackRest's backups (only the host that is the primary at the time takes them).
# Updating the host that is the primary first hands the role to the synchronous standby (a switchover: no committed
# write lost, a few seconds of reconnecting), so the update restarts a standby, never the primary.
#   MASSLAK_DB_WATCHDOG=off   no watchdog device (the default loads softdog and passes /dev/watchdog to Patroni)
set -euo pipefail
cd "$(dirname "$0")/../../.."
bundle="${1:?the bundle of this host: deploy/production/ha/bundles/dbN.tar.gz from the application host}"
dir="${2:-/etc/masslak/db-host}"
fail() { echo "install-db-host: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail "run as root"
command -v docker >/dev/null || fail "Docker is needed (deploy/server-setup.sh installs it)"
command -v cosign >/dev/null || fail "cosign is needed: the host checks the signature of the image it runs"
umask 077
mkdir -p "$dir"; chmod 0700 "$dir"
tar -xzf "$bundle" -C "$dir"
chown 70:70 "$dir/tls/cluster.key"; chmod 0600 "$dir/tls/cluster.key"; chmod 0644 "$dir/tls/ca.crt" "$dir/tls/cluster.crt"
value() { { sed -n "s/^$1=//p" "$dir/$2" 2>/dev/null || true; } | tail -1; }
name="$(value PATRONI_NAME db-host.env)"
address="$(value PATRONI_RESTAPI_CONNECT_ADDRESS db-host.env)"; address="${address%:8008}"
[ -n "$name" ] && [ -n "$address" ] || fail "$bundle is not a database host's bundle"
ip -o addr show 2>/dev/null | grep -q " $address/" || fail "$address (the bundle of $name) is not an address of this host"
project="masslak-$name"
compose() { docker compose --env-file "$dir/compose.env" -p "$project" "${files[@]}" "$@"; }
rest() { curl -sf --cacert "$dir/tls/ca.crt" "https://$address:8008$1"; }
status() { curl -s -o /dev/null -w '%{http_code}' --cacert "$dir/tls/ca.crt" "https://$address:8008$1" 2>/dev/null || true; }

# the release's signed database image, checked and pulled by digest
images="$dir/IMAGES"; [ -s "$images" ] || images=IMAGES
[ -s "$images" ] || fail "no IMAGES: run this from the signed release archive (RUNBOOKS.md, section 19)"
version="$(sed -n 's/^version=//p' "$images" | tail -1)"; commit="$(sed -n 's/^commit=//p' "$images" | tail -1)"
tag="${version:-release}-$(printf '%s' "$commit" | cut -c1-12)"
key="$(value MASSLAK_IMAGE_KEY images.env)"
MASSLAK_IMAGE_NAMES=masslak-db MASSLAK_IMAGE_KEY="${key:+$dir/$key}" \
  MASSLAK_IMAGE_REGISTRY_HTTP="$(value MASSLAK_IMAGE_REGISTRY_HTTP images.env)" \
  MASSLAK_RELEASE_REPO="$(value MASSLAK_RELEASE_REPO images.env)" ./deploy/images.sh pull "$images" "$tag"

files=(-f deploy/production/ha/db-host.yml)
if [ "${MASSLAK_DB_WATCHDOG:-on}" != off ]; then
  [ -c /dev/watchdog ] || modprobe softdog 2>/dev/null || true
  if [ -c /dev/watchdog ]; then files+=(-f deploy/production/ha/db-host-watchdog.yml)
  else echo "warning: no watchdog device on this host (modprobe softdog failed); Patroni runs without one" >&2; fi
fi
printf 'MASSLAK_DB_HOST_DIR=%s\nMASSLAK_IMAGE_TAG=%s\n' "$dir" "$tag" > "$dir/compose.env"

# an update that restarts the primary (another image, other settings) hands the role to the synchronous standby
# first, so what restarts is a standby
installed="$(cat "$dir/installed" 2>/dev/null || true)"
wanted="$(cat "$dir/db-host.env" "$dir/etcd.env" deploy/production/ha/db-host*.yml <(echo "$tag ${files[*]}") | sha256sum | cut -d' ' -f1)"
if [ "$(status /primary)" = 200 ] && [ -n "$installed" ] && [ "$installed" != "$wanted" ]; then
  other="$(rest /cluster | python3 -c 'import json,sys; m=[x["name"] for x in json.load(sys.stdin)["members"] if x.get("role") == "sync_standby" and x.get("state") == "streaming"]; print(m[0] if m else "")')"
  [ -n "$other" ] || fail "this host is the primary and no synchronous standby is streaming: update the other host first"
  echo "this host is the primary: handing the role to $other before the update"
  docker exec "$project-patroni-1" patronictl -c /etc/patroni/patroni.yml switchover --leader "$name" --candidate "$other" --force
  for _ in $(seq 1 60); do [ "$(status /replica)" = 200 ] && break; sleep 2; done
fi

compose up -d
for i in $(seq 1 90); do                   # Patroni answers on its REST API
  [ "$(status /liveness)" != 000 ] && break
  [ "$i" = 90 ] && { compose logs --tail 60; fail "$name does not answer on https://$address:8008"; }
  sleep 2
done
# its PostgreSQL runs once etcd has a majority: with the application host's member up (deploy/install.sh starts it),
# at once on the first host; then as the copy of the primary on the second
for _ in $(seq 1 90); do rest /health >/dev/null 2>&1 && break; sleep 2; done
echo "$wanted" > "$dir/installed"

# pgBackRest's backups from whichever host is the primary (masslak-backup-if-primary), like deploy/pitr on one host
cat > /etc/cron.d/masslak-pgbackrest-"$name" <<CRON
# Written by deploy/production/ha/install-db-host.sh: only the primary at the time backs up
30 1 * * 0   root docker exec -u postgres $project-patroni-1 masslak-backup-if-primary full >> /var/log/masslak-pgbackrest.log 2>&1
30 1 * * 1-6 root docker exec -u postgres $project-patroni-1 masslak-backup-if-primary diff >> /var/log/masslak-pgbackrest.log 2>&1
CRON
chmod 0644 /etc/cron.d/masslak-pgbackrest-"$name"
if rest /health >/dev/null 2>&1; then
  rest /patroni | python3 -c 'import json,sys; p=json.load(sys.stdin); print("%s: %s, %s, timeline %s" % (sys.argv[1], p.get("role"), p.get("state"), p.get("timeline")))' "$name"
else
  echo "$name runs and waits for etcd's majority: start the application host's member (deploy/install.sh) or the other database host"
fi
echo "delete the bundle now that it is installed: shred -u $bundle"
