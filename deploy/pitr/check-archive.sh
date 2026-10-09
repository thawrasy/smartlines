#!/usr/bin/env bash
# Proves that WAL archiving works, at once (review of release 1.47.0, R-40): after PostgreSQL restarts (an update, a
# configuration change, a failover) a broken archive_command would otherwise be noticed only by the alert minutes
# later, and every minute without archiving widens what a point-in-time restore could lose.
# It switches to a new WAL segment and waits until the finished one is archived. Run by deploy/update.sh after the
# stack is ready; by hand: ./deploy/pitr/check-archive.sh [seconds to wait, default 90]
set -euo pipefail
cd "$(dirname "$0")/../.."
while IFS= read -r line; do case "$line" in ''|\#*) ;; *) export "$line" ;; esac; done < deploy/.env
wait_s="${1:-90}"
sql() { docker compose --env-file deploy/.env exec -T db psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-masslak}" -qAt -c "$1"; }
if [ "$(sql "SHOW archive_mode")" = off ]; then
  echo "WAL archiving is off on this server (no point-in-time recovery layer): nothing to check"
  exit 0
fi
segment="$(sql "SELECT pg_walfile_name(pg_switch_wal())")"
for _ in $(seq 1 "$wait_s"); do
  last="$(sql "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver")"
  # segment names of one timeline sort in the order they were written
  if [ -n "$last" ] && [[ ! "$last" < "$segment" ]]; then
    echo "WAL archiving works: $segment archived"
    exit 0
  fi
  sleep 1
done
echo "WAL segment $segment was not archived within ${wait_s}s: point-in-time recovery is at risk" \
     "(pg_stat_archiver: $(sql "SELECT failed_count || ' failures, last ' || coalesce(last_failed_wal, 'none') FROM pg_stat_archiver"))" >&2
exit 4
