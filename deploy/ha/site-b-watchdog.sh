#!/usr/bin/env bash
# Watchdog of the second site (review of release 1.47.0, R-43). It watches and reports; it never promotes: losing the
# main site is declared by a person (RUNBOOKS.md, section 23), because a cut link looks the same as a lost site.
#
# Every minute (deploy/ha/masslak-site-b-watchdog.timer) it checks, on the second site's standby leader:
#   * that it receives WAL from the main site (pg_stat_wal_receiver), and how far its replay is behind;
#   * that the main site's primary answers: one of its database hosts (MASSLAK_MAIN_SITE_HOSTS, its MASSLAK_DB_HOSTS)
#     accepts connections and its Patroni REST API, over TLS with the main site's authority, says it is the primary;
# and writes the figures for node_exporter's textfile collector, where Prometheus reads them (alerts SiteBNotStreaming,
# SiteBLagging, MainSiteUnreachableFromSiteB). With MASSLAK_WATCHDOG_WEBHOOK set it also posts a message when the
# state changes, so the people on call hear of it even if the main site's monitoring went down with it.
set -uo pipefail
main_hosts="${MASSLAK_MAIN_SITE_HOSTS:-10.0.0.11,10.0.0.12}"
main_ca="${MASSLAK_MAIN_SITE_CA:-/etc/masslak/main-site-ca.crt}"
out_dir="${MASSLAK_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
state_file="${MASSLAK_WATCHDOG_STATE:-/var/lib/masslak/site-b-watchdog.state}"
psql_local() { psql -h /var/run/postgresql -U postgres -d postgres -qAtX -c "$1" 2>/dev/null; }

streaming="$(psql_local "SELECT count(*) FROM pg_stat_wal_receiver WHERE status = 'streaming'")"
streaming="${streaming:-0}"
lag="$(psql_local "SELECT coalesce(extract(epoch FROM now() - pg_last_xact_replay_timestamp()), -1)")"
lag="${lag:--1}"
in_recovery="$(psql_local "SELECT pg_is_in_recovery()::int")"
in_recovery="${in_recovery:-0}"
reachable=0
for h in ${main_hosts//,/ }; do
  if pg_isready -q -h "$h" -p 5432 -t 5 && curl -fsS -m 5 --cacert "$main_ca" "https://$h:8008/primary" >/dev/null 2>&1; then reachable=1; fi
done

mkdir -p "$out_dir" "$(dirname "$state_file")"
tmp="$(mktemp "$out_dir/.masslak_site_b.XXXXXX")"
cat > "$tmp" <<METRICS
# HELP masslak_site_b_streaming 1 when the second site's standby receives WAL from the main site
# TYPE masslak_site_b_streaming gauge
masslak_site_b_streaming $streaming
# HELP masslak_site_b_replay_lag_seconds Age of the last transaction the second site replayed (-1: unknown)
# TYPE masslak_site_b_replay_lag_seconds gauge
masslak_site_b_replay_lag_seconds $lag
# HELP masslak_site_b_in_recovery 1 while the second site is a standby (0 after a promotion)
# TYPE masslak_site_b_in_recovery gauge
masslak_site_b_in_recovery $in_recovery
# HELP masslak_site_b_main_reachable 1 when the main site's primary answers from the second site
# TYPE masslak_site_b_main_reachable gauge
masslak_site_b_main_reachable $reachable
# HELP masslak_site_b_watchdog_last_run_timestamp_seconds When the watchdog last ran
# TYPE masslak_site_b_watchdog_last_run_timestamp_seconds gauge
masslak_site_b_watchdog_last_run_timestamp_seconds $(date +%s)
METRICS
chmod 0644 "$tmp" && mv "$tmp" "$out_dir/masslak_site_b.prom"

state="streaming=$streaming reachable=$reachable recovery=$in_recovery"
if [ -n "${MASSLAK_WATCHDOG_WEBHOOK:-}" ] && [ "$state" != "$(cat "$state_file" 2>/dev/null)" ]; then
  text="Masslak second site: WAL $([ "$streaming" = 1 ] && echo streaming || echo 'NOT streaming'), main site $([ "$reachable" = 1 ] && echo reachable || echo 'NOT reachable'), replay lag ${lag}s. Promotion is a decision for a person (RUNBOOKS.md, section 23)."
  curl -fsS -m 10 -H 'Content-Type: application/json' -d "{\"text\": \"$text\"}" "$MASSLAK_WATCHDOG_WEBHOOK" >/dev/null || true
fi
echo "$state" > "$state_file"
