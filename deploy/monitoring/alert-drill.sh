#!/usr/bin/env bash
# Alert drill (reviews of October 2026, H-07): proves that an alert travels from Alertmanager to the people on call.
#   ./deploy/monitoring/alert-drill.sh [seconds to wait, default 120]
# It posts a synthetic alert (MasslakAlertDrill, severity page) to Alertmanager, checks that Alertmanager routes it to
# the page receiver, that its webhook deliveries rise and none fails meanwhile, then resolves it. The person on call
# confirms the message arrived, with the drill's identifier; record the drill (date, identifier, who confirmed) as
# launch gate evidence (docs/operations/LAUNCH_GATES.md). Exit 0 when Alertmanager delivered without a failure.
set -euo pipefail
cd "$(dirname "$0")/../.."
wait_s="${1:-120}"
dc() { docker compose --env-file deploy/.env "$@"; }
am() { dc exec -T alertmanager wget -qO- "$@"; }
counter() {                              # sum of an Alertmanager counter for the webhook integration
  am http://localhost:9093/metrics | awk -v m="$1" '$1 ~ "^"m"\\{" && $1 ~ /integration="webhook"/ { s += $2 } END { printf "%d", s }'
}
id="drill-$(date -u +%Y%m%dT%H%M%SZ)"
sent_before="$(counter alertmanager_notifications_total)"
failed_before="$(counter alertmanager_notifications_failed_total)"
alert() {                                # starts (no end) or resolves (end = now) the drill alert
  local ends=""; [ -n "${1:-}" ] && ends=",\"endsAt\":\"$1\""
  am --header 'Content-Type: application/json' --post-data \
    "[{\"labels\":{\"alertname\":\"MasslakAlertDrill\",\"severity\":\"page\",\"drill\":\"$id\"},\"annotations\":{\"summary\":\"Alert drill $id: tell the operations lead you received it\"}$ends}]" \
    http://localhost:9093/api/v2/alerts >/dev/null
}
alert
echo "drill alert $id posted"
routed=false
for _ in $(seq 1 "$wait_s"); do
  if am "http://localhost:9093/api/v2/alerts?filter=drill%3D%22$id%22" | grep -q '"name":"page"'; then routed=true; fi
  sent="$(counter alertmanager_notifications_total)"
  if [ "$routed" = true ] && [ "$sent" -gt "$sent_before" ]; then break; fi
  sleep 1
done
failed="$(counter alertmanager_notifications_failed_total)"
alert "$(date -u +%Y-%m-%dT%H:%M:%SZ)"            # resolved: the receivers get the all-clear
if [ "$routed" != true ]; then echo "the drill alert was not routed to the page receiver (deploy/production/alertmanager.yml)" >&2; exit 1; fi
if [ "$failed" -gt "$failed_before" ]; then
  echo "Alertmanager failed to deliver $((failed - failed_before)) notification(s): check the receivers in deploy/production/secrets" >&2; exit 1
fi
if [ "$sent" -le "$sent_before" ]; then echo "no notification left Alertmanager within ${wait_s}s" >&2; exit 1; fi
echo "Alertmanager delivered the drill alert $id to the page receiver ($((sent - sent_before)) webhook notification(s), no failure)."
echo "Ask the person on call to confirm they received '$id', and record it as launch gate evidence."
