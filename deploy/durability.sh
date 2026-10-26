#!/usr/bin/env bash
# Zero data loss as a setting (owner's decision 1; review of release 1.47.0, R-39).
#
#   MASSLAK_ZERO_DATA_LOSS=on   every commit waits until a standby has it: a booking or payment the platform confirmed
#                               survives the loss of the primary. With no standby able to confirm, commits wait (the
#                               platform pauses) rather than be confirmed without a copy (alert CommitsWaitingForStandby).
#   MASSLAK_ZERO_DATA_LOSS=off  commits are confirmed by the primary alone; a standby may miss the last seconds.
#
# Applied on install and on every update, and by hand after changing deploy/.env: ./deploy/durability.sh
# On one host the standby is the read replica (db-replica, named replica1). With two database hosts
# (MASSLAK_DB_LAYOUT=ha, H-01) the standby is the other host, and the setting goes to the Patroni cluster through its
# REST API (synchronous_mode_strict; masslak-patroni in the db proxy). With two hosts, "on" also means that while one
# host is down every commit waits for it to come back: RUNBOOKS.md, section 3, says when to switch it off.
set -euo pipefail
cd "$(dirname "$0")/.."
while IFS= read -r line; do case "$line" in ''|\#*) ;; *) export "$line" ;; esac; done < deploy/.env
mode="${MASSLAK_ZERO_DATA_LOSS:-off}"
sql() { docker compose --env-file deploy/.env exec -T db psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-masslak}" -qAt -v ON_ERROR_STOP=1 -c "$1"; }
if [ "${MASSLAK_DB_LAYOUT:-single}" = ha ]; then
  case "$mode" in on|off) ;; *) echo "MASSLAK_ZERO_DATA_LOSS must be on or off (now: $mode)" >&2; exit 2 ;; esac
  docker compose --env-file deploy/.env exec -T db masslak-patroni durability "$mode"
  echo "zero data loss: $mode (commits wait for a standby: $(sql "SELECT current_setting('synchronous_standby_names') <> ''"))"
  exit 0
fi
case "$mode" in
  on)
    # the standby must be streaming under its name first, or the first commit would wait for it; a replica started
    # before it had a name (an older release) is restarted once to take it
    streaming() { [ "$(sql "SELECT count(*) FROM pg_stat_replication WHERE application_name = 'replica1' AND state = 'streaming'")" = 1 ]; }
    streaming || docker compose --env-file deploy/.env restart db-replica >/dev/null
    for _ in $(seq 1 60); do
      streaming && break
      sleep 2
    done
    streaming || { echo "zero data loss not applied: the standby replica1 is not streaming" >&2; exit 1; }
    sql "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica1)'"
    sql "ALTER SYSTEM SET synchronous_commit = 'on'" ;;
  off)
    sql "ALTER SYSTEM SET synchronous_standby_names = ''"
    sql "ALTER SYSTEM SET synchronous_commit = 'on'" ;;
  *) echo "MASSLAK_ZERO_DATA_LOSS must be on or off (now: $mode)" >&2; exit 2 ;;
esac
sql "SELECT pg_reload_conf()" >/dev/null
echo "zero data loss: $mode (commits wait for a standby: $(sql "SELECT current_setting('synchronous_standby_names') <> ''"))"
