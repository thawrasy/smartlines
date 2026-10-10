#!/usr/bin/env bash
# Alert drill (reviews of October 2026, H-07): proves that an alert travels from Alertmanager to the people on call.
#   ./deploy/monitoring/alert-drill.sh [seconds to wait, default 120]
# It posts a synthetic alert (MasslakAlertDrill, severity page) to Alertmanager, checks that Alertmanager routes it to
# the page receiver and that a webhook request to that receiver succeeded, then resolves it. The person on call
# confirms the message arrived, with the drill's identifier; record the drill (date, identifier, who confirmed) as
# launch gate evidence (docs/operations/LAUNCH_GATES.md). Exit 0 when the page receiver accepted the drill.
# It reads Alertmanager's request counters per receiver (--enable-feature=receiver-name-in-metrics, set in the
# production and staging overlays): the heartbeat to the dead man's switch every minute never counts as the page.
set -euo pipefail
cd "$(dirname "$0")/../.."
wait_s="${1:-120}"
receiver=page
dc() { docker compose --env-file deploy/.env "$@"; }
am() { dc exec -T alertmanager wget -qO- "$@"; }
counter() {                              # webhook requests to the page receiver: all of them, or the failed ones
  am http://localhost:9093/metrics | awk -v m="$1" -v r="receiver_name=\"$receiver\"" \
    '$1 ~ "^"m"\\{" && index($1, "integration=\"webhook\"") && index($1, r) { s += $2; n++ } END { if (n) printf "%d", s; else print "none" }'
}
sent_before="$(counter alertmanager_notification_requests_total)"
failed_before="$(counter alertmanager_notification_requests_failed_total)"
if [ "$sent_before" = none ]; then
  echo "Alertmanager does not count requests per receiver: start it with --enable-feature=receiver-name-in-metrics" >&2; exit 1
fi
id="drill-$(date -u +%Y%m%dT%H%M%SZ)"
alert() {                                # starts (no end) or resolves (end = now) the drill alert
  local ends=""; [ -n "${1:-}" ] && ends=",\"endsAt\":\"$1\""
  am --header 'Content-Type: application/json' --post-data \
    "[{\"labels\":{\"alertname\":\"MasslakAlertDrill\",\"severity\":\"page\",\"drill\":\"$id\"},\"annotations\":{\"summary\":\"Alert drill $id: tell the operations lead you received it\"}$ends}]" \
    http://localhost:9093/api/v2/alerts >/dev/null
}
alert
echo "drill alert $id posted"
routed=false delivered=0 failed=0
for _ in $(seq 1 "$wait_s"); do
  if am "http://localhost:9093/api/v2/alerts?filter=drill%3D%22$id%22" | grep -q "\"name\":\"$receiver\""; then routed=true; fi
  sent="$(counter alertmanager_notification_requests_total)"
  failed=$(( $(counter alertmanager_notification_requests_failed_total) - failed_before ))
  delivered=$(( sent - sent_before - failed ))   # requests the receiver answered with success
  if [ "$routed" = true ] && [ "$delivered" -gt 0 ]; then break; fi
  sleep 1
done
alert "$(date -u +%Y-%m-%dT%H:%M:%SZ)"            # resolved: the receivers get the all-clear
if [ "$routed" != true ]; then echo "the drill alert was not routed to the $receiver receiver (alertmanager.yml)" >&2; exit 1; fi
if [ "$delivered" -le 0 ]; then
  echo "the $receiver receiver did not accept the drill within ${wait_s}s ($failed failed request(s)): check its URL in the secrets directory" >&2
  exit 1
fi
[ "$failed" -gt 0 ] && echo "warning: $failed request(s) to the $receiver receiver failed before one succeeded" >&2
echo "The $receiver receiver accepted the drill alert $id ($delivered webhook request(s))."
echo "Ask the person on call to confirm they received '$id', and record it as launch gate evidence."
