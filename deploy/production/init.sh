#!/usr/bin/env bash
# Prepares what the production profile needs on this server (reviews of October 2026, package 2). Run as root by
# deploy/install.sh and deploy/update.sh on a production server; safe to run again (it never replaces what exists).
#
#   * an internal certificate authority and the database's certificates (H-05): the server certificate of the
#     database, the read replica and PgBouncer (names db, db-replica, pgbouncer and MASSLAK_DB_TLS_NAMES), and the
#     client certificate of the warehouse login masslak_cdc (H-10). The authority's key signs nothing else: move
#     deploy/production/tls/ca.key to offline storage once the certificates are made, and bring it back to renew them;
#   * the monitoring's secrets as files (H-07): the token Prometheus scrapes the API with and Grafana's administrator
#     password;
#   * COMPOSE_FILE in deploy/.env, so every docker compose command on this server uses the production profile.
#
# The receivers of alerts (deploy/production/secrets/*_webhook_url) are the operator's to write; the preflight of
# deploy/install.sh and deploy/update.sh refuses to go on while they are placeholders.
set -euo pipefail
cd "$(dirname "$0")"
env_file=../.env
[ -f "$env_file" ] || { echo "deploy/.env is missing: run deploy/init-env.sh first" >&2; exit 1; }
value() { { sed -n "s/^$1=//p" "$env_file" || true; } | tail -1; }
umask 077

# ---- TLS: internal authority, server and client certificates ------------------------------------------------------
tls=tls; mkdir -p "$tls"
days_ca=3650 days_cert=825
if [ ! -s "$tls/ca.key" ] && [ ! -s "$tls/ca.crt" ]; then
  openssl req -x509 -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days "$days_ca" \
    -subj "/CN=Masslak internal CA $(date -u +%Y-%m)" -keyout "$tls/ca.key" -out "$tls/ca.crt" 2>/dev/null
  echo "created the internal certificate authority (deploy/production/tls/ca.crt)"
fi
issue() {                                  # name, subject CN, extensions file
  local name="$1" cn="$2" ext="$3"
  [ -s "$tls/$name.crt" ] && return 0
  [ -s "$tls/ca.key" ] || { echo "deploy/production/tls/ca.key is needed to issue $name.crt: bring it back from offline storage" >&2; exit 1; }
  openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -subj "/CN=$cn" \
    -keyout "$tls/$name.key" -out "$tls/$name.csr" 2>/dev/null
  openssl x509 -req -in "$tls/$name.csr" -CA "$tls/ca.crt" -CAkey "$tls/ca.key" -CAcreateserial -sha256 \
    -days "$days_cert" -extfile "$ext" -out "$tls/$name.crt" 2>/dev/null
  rm -f "$tls/$name.csr"
  echo "issued $name.crt for $cn"
}
names="DNS:db,DNS:db-replica,DNS:pgbouncer,DNS:localhost"
for n in $(value MASSLAK_DB_TLS_NAMES | tr ',' ' '); do names="$names,DNS:$n"; done
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$names" > "$tls/server.ext"
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n' > "$tls/client.ext"
issue server db "$tls/server.ext"
issue masslak_cdc masslak_cdc "$tls/client.ext"
rm -f "$tls/server.ext" "$tls/client.ext"
# The database images run as postgres (uid 70): they read their keys as that user. The authority's certificate is public.
chown 70:70 "$tls/server.key" "$tls/masslak_cdc.key"
chmod 0600 "$tls/server.key" "$tls/masslak_cdc.key"
chmod 0644 "$tls/ca.crt" "$tls/server.crt" "$tls/masslak_cdc.crt"
[ ! -e "$tls/ca.key" ] || chmod 0600 "$tls/ca.key"
chmod 0755 "$tls"
# what the API, the worker and the migration trust: the internal authority, and Vault's own authority when its
# certificate is not from a public one (copy it to trust/vault-ca.crt and set MASSLAK_VAULT_CA_FILE=/etc/masslak/trust/vault-ca.crt)
mkdir -p trust
cp "$tls/ca.crt" trust/ca.crt
chmod 0755 trust; chmod 0644 trust/*.crt

# ---- monitoring secrets -------------------------------------------------------------------------------------------
sec=secrets; mkdir -p "$sec"
rand() { head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-40; }
token="$(value MASSLAK_METRICS_TOKEN)"
if [ -z "$token" ]; then
  token="$(rand)"; echo "MASSLAK_METRICS_TOKEN=$token" >> "$env_file"; echo "added MASSLAK_METRICS_TOKEN to deploy/.env"
fi
printf '%s' "$token" > "$sec/metrics_token"
[ -s "$sec/grafana_admin_password" ] || rand > "$sec/grafana_admin_password"
for r in page ticket deadman; do
  [ -s "$sec/${r}_webhook_url" ] || echo "http://127.0.0.1:9/replace-with-the-${r}-receiver" > "$sec/${r}_webhook_url"
done
# Prometheus, Alertmanager and Grafana read these as their own users
chmod 0644 "$sec"/metrics_token "$sec"/grafana_admin_password "$sec"/*_webhook_url
chmod 0755 "$sec"

# ---- the second site's metrics, when there is one (Prometheus reads targets/site-b.yml) ---------------------------
mkdir -p targets
site_b="$(value MASSLAK_SITE_B_METRICS)"            # host:port of the second site's node_exporter
if [ -n "$site_b" ]; then printf -- '- targets: ["%s"]\n  labels: {site: b}\n' "$site_b" > targets/site-b.yml
else echo "[]" > targets/site-b.yml; fi
chmod 0755 targets; chmod 0644 targets/site-b.yml

# ---- every compose command on this server uses the production profile -------------------------------------------
files="docker-compose.yml:deploy/production/docker-compose.production.yml"
extra="$(value MASSLAK_COMPOSE_EXTRA)"                 # further overlays (telemetry, warehouse), colon-separated
[ -z "$extra" ] || files="$files:$extra"
if grep -q '^COMPOSE_FILE=' "$env_file"; then sed -i "s|^COMPOSE_FILE=.*|COMPOSE_FILE=$files|" "$env_file"
else echo "COMPOSE_FILE=$files" >> "$env_file"; fi
echo "production profile ready (COMPOSE_FILE=$files)"
