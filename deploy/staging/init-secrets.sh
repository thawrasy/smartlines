#!/bin/sh
# Creates the staging secrets that are files (not environment variables): the metrics token Prometheus sends, the
# Grafana admin password, and the Alertmanager receiver URLs. Prints the lines to add to deploy/.env.
set -eu
D="$(cd "$(dirname "$0")" && pwd)/secrets"
mkdir -p "$D"; umask 077
rand() { head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-40; }
[ -s "$D/metrics_token" ] || rand > "$D/metrics_token"
[ -s "$D/grafana_admin_password" ] || rand > "$D/grafana_admin_password"
for r in page ticket; do
  [ -s "$D/${r}_webhook_url" ] || echo "http://127.0.0.1:9/replace-with-the-${r}-receiver" > "$D/${r}_webhook_url"
done
# Prometheus and Grafana read these as their own users
chmod 0644 "$D"/metrics_token "$D"/grafana_admin_password "$D"/*_webhook_url
echo "Add to deploy/.env (once):"
echo "MASSLAK_METRICS_TOKEN=$(cat "$D/metrics_token")"
grep -q '^PGBACKREST_REPO1_CIPHER_PASS=.' "$(dirname "$D")/../.env" 2>/dev/null || echo "PGBACKREST_REPO1_CIPHER_PASS=$(rand)"
echo "Then put the on-call and team-queue webhook URLs in $D/page_webhook_url and ticket_webhook_url."
