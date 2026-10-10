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
#   * with two database hosts (MASSLAK_DB_LAYOUT=ha, H-01): the cluster's certificate, which both database hosts and
#     the third etcd member on this server present to each other and to the application, the REST API's password
#     and etcd's cluster token, and one bundle per database host (deploy/production/ha/bundles/db1.tar.gz, db2.tar.gz)
#     for deploy/production/ha/install-db-host.sh on that host;
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

# ---- two database hosts (H-01): the cluster's certificate, etcd, and each host's bundle ---------------------------
rand() { head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-40; }
put() { if grep -q "^$1=" "$env_file"; then sed -i "s|^$1=.*|$1=$2|" "$env_file"; else echo "$1=$2" >> "$env_file"; fi; }
layout="$(value MASSLAK_DB_LAYOUT)"
if [ "$layout" = ha ]; then
  ipv4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  IFS=, read -r -a hosts <<< "$(value MASSLAK_DB_HOSTS)"
  witness="$(value MASSLAK_DB_WITNESS)"
  [ "${#hosts[@]}" = 2 ] && [[ "${hosts[0]}" =~ $ipv4 ]] && [[ "${hosts[1]}" =~ $ipv4 ]] && [ "${hosts[0]}" != "${hosts[1]}" ] \
    || { echo "MASSLAK_DB_HOSTS must hold the two database hosts' private IPv4 addresses, comma-separated" >&2; exit 1; }
  [[ "$witness" =~ $ipv4 ]] \
    || { echo "MASSLAK_DB_WITNESS must hold this server's private IPv4 address (the third etcd member)" >&2; exit 1; }
  names="DNS:db,DNS:db-replica,DNS:localhost,IP:127.0.0.1,IP:${hosts[0]},IP:${hosts[1]},IP:$witness"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=%s\n' "$names" > "$tls/cluster.ext"
  issue cluster masslak-cluster "$tls/cluster.ext"
  rm -f "$tls/cluster.ext"
  for a in "${hosts[@]}" "$witness"; do      # the hosts changed since it was issued: it must be issued again
    openssl x509 -noout -ext subjectAltName -in "$tls/cluster.crt" | grep -q "IP Address:$a\(,\|$\)" \
      || { echo "deploy/production/tls/cluster.crt does not name $a: move it and cluster.key away and run again" >&2; exit 1; }
  done
  chown 70:70 "$tls/cluster.key"; chmod 0600 "$tls/cluster.key"; chmod 0644 "$tls/cluster.crt"
  [ -n "$(value MASSLAK_PATRONI_REST_PASSWORD)" ] || { put MASSLAK_PATRONI_REST_PASSWORD "$(rand)"; echo "added MASSLAK_PATRONI_REST_PASSWORD to deploy/.env"; }
  [ -n "$(value MASSLAK_ETCD_TOKEN)" ] || put MASSLAK_ETCD_TOKEN "masslak-$(rand | cut -c1-16)"
  members="db1=https://${hosts[0]}:2380,db2=https://${hosts[1]}:2380,witness=https://$witness:2380"
  etcd_env() {                             # member name, address: etcd over TLS, a client certificate required
    printf '%s\n' "ETCD_NAME=$1" "ETCD_DATA_DIR=/var/lib/etcd" \
      "ETCD_LISTEN_PEER_URLS=https://$2:2380" "ETCD_INITIAL_ADVERTISE_PEER_URLS=https://$2:2380" \
      "ETCD_LISTEN_CLIENT_URLS=https://$2:2379" "ETCD_ADVERTISE_CLIENT_URLS=https://$2:2379" \
      "ETCD_INITIAL_CLUSTER=$members" "ETCD_INITIAL_CLUSTER_TOKEN=$(value MASSLAK_ETCD_TOKEN)" "ETCD_INITIAL_CLUSTER_STATE=new" \
      "ETCD_CERT_FILE=/tls/cluster.crt" "ETCD_KEY_FILE=/tls/cluster.key" "ETCD_TRUSTED_CA_FILE=/tls/ca.crt" \
      "ETCD_CLIENT_CERT_AUTH=true" "ETCD_PEER_CERT_FILE=/tls/cluster.crt" "ETCD_PEER_KEY_FILE=/tls/cluster.key" \
      "ETCD_PEER_TRUSTED_CA_FILE=/tls/ca.crt" "ETCD_PEER_CLIENT_CERT_AUTH=true"
  }
  mkdir -p ../env; chmod 0700 ../env
  etcd_env witness "$witness" > ../env/etcd.env; chmod 0600 ../env/etcd.env
  bundles=ha/bundles; mkdir -p "$bundles"; chmod 0700 "$bundles"
  for i in 1 2; do
    a="${hosts[$((i - 1))]}" work="$(mktemp -d)"
    mkdir "$work/tls"; cp "$tls/ca.crt" "$tls/cluster.crt" "$tls/cluster.key" "$work/tls/"
    etcd_env "db$i" "$a" > "$work/etcd.env"
    {
      printf '%s\n' "PATRONI_NAME=db$i" "PATRONI_RESTAPI_LISTEN=$a:8008" "PATRONI_RESTAPI_CONNECT_ADDRESS=$a:8008" \
        "PATRONI_POSTGRESQL_LISTEN=$a:5432" "PATRONI_POSTGRESQL_CONNECT_ADDRESS=$a:5432" \
        "PATRONI_ETCD3_HOSTS=${hosts[0]}:2379,${hosts[1]}:2379,$witness:2379" \
        "PATRONI_SUPERUSER_USERNAME=$(value POSTGRES_USER | grep . || echo postgres)" \
        "PATRONI_SUPERUSER_PASSWORD=$(value POSTGRES_PASSWORD)" "PATRONI_REPLICATION_PASSWORD=$(value MASSLAK_REPLICATION_PASSWORD)" \
        "PATRONI_RESTAPI_USERNAME=masslak" "PATRONI_RESTAPI_PASSWORD=$(value MASSLAK_PATRONI_REST_PASSWORD)" \
        "POSTGRES_DB=$(value POSTGRES_DB | grep . || echo masslak)"
      grep -E '^(PGBACKREST_[A-Z0-9_]*|MASSLAK_WAREHOUSE_ADDRESS|MASSLAK_DB_NETWORK)=.' "$env_file" || true
    } > "$work/db-host.env"
    # the signed image this release names, and how to check it (deploy/images.sh)
    [ ! -s ../../IMAGES ] || cp ../../IMAGES "$work/IMAGES"
    : > "$work/images.env"
    key="$(value MASSLAK_IMAGE_KEY)"
    if [ -n "$key" ] && [ -s "$key" ]; then cp "$key" "$work/image-key.pub"; echo "MASSLAK_IMAGE_KEY=image-key.pub" >> "$work/images.env"; fi
    for k in MASSLAK_IMAGE_REGISTRY_HTTP MASSLAK_RELEASE_REPO; do
      [ -z "$(value "$k")" ] || echo "$k=$(value "$k")" >> "$work/images.env"
    done
    tar -czf "$bundles/db$i.tar.gz.tmp" -C "$work" . && mv "$bundles/db$i.tar.gz.tmp" "$bundles/db$i.tar.gz"
    rm -rf "$work"
  done
  echo "two database hosts: bundles written to deploy/production/ha/bundles (db1 for ${hosts[0]}, db2 for ${hosts[1]})"
fi

# ---- monitoring secrets -------------------------------------------------------------------------------------------
sec=secrets; mkdir -p "$sec"
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
[ "$layout" != ha ] || files="$files:deploy/production/ha/docker-compose.ha.yml"
extra="$(value MASSLAK_COMPOSE_EXTRA)"                 # further overlays (telemetry, warehouse), colon-separated
[ -z "$extra" ] || files="$files:$extra"
if grep -q '^COMPOSE_FILE=' "$env_file"; then sed -i "s|^COMPOSE_FILE=.*|COMPOSE_FILE=$files|" "$env_file"
else echo "COMPOSE_FILE=$files" >> "$env_file"; fi
echo "production profile ready (COMPOSE_FILE=$files)"
