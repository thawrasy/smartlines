#!/usr/bin/env bash
# Host side of the production preflight (reviews of October 2026, package 2), run by deploy/install.sh and
# deploy/update.sh on a production server before anything is built or changed. It checks what deploy/.env and this
# directory declare; the migration then proves the database side on the database itself (backend/app/tools/preflight.py).
# Exit 0 when the setup is complete, 1 with one line per gap.
set -uo pipefail
cd "$(dirname "$0")"
env_file=../.env
value() { { sed -n "s/^$1=//p" "$env_file" 2>/dev/null || true; } | tail -1; }
gaps=()
gap() { gaps+=("$1"); }

[ "$(value MASSLAK_ENVIRONMENT)" = production ] || { echo "not a production server (MASSLAK_ENVIRONMENT): nothing to check"; exit 0; }
[ "$(value MASSLAK_SANDBOX)" = true ] && gap "MASSLAK_SANDBOX=true on a production server"

# the key service (H-06): data keys are wrapped by Vault; the API and the worker never hold them in clear
[ "$(value MASSLAK_KMS_PROVIDER)" = vault ] || gap "MASSLAK_KMS_PROVIDER=vault is required: the data keys are opened by the key service"
case "$(value MASSLAK_VAULT_ADDR)" in https://*) ;; *) gap "MASSLAK_VAULT_ADDR must be the key service's https:// address" ;; esac
[ -n "$(value MASSLAK_VAULT_TOKEN)" ] || gap "MASSLAK_VAULT_TOKEN is missing (a token limited to the transit key's encrypt and decrypt)"
ca="$(value MASSLAK_VAULT_CA_FILE)"
if [ -n "$ca" ]; then
  case "$ca" in /etc/masslak/trust/*) [ -s "trust/${ca#/etc/masslak/trust/}" ] || gap "MASSLAK_VAULT_CA_FILE names ${ca#/etc/masslak/trust/}, which is not in deploy/production/trust" ;;
    *) gap "MASSLAK_VAULT_CA_FILE must be a file in /etc/masslak/trust (deploy/production/trust on the host)" ;; esac
fi

# WAL archiving to a repository off this host (H-02), and backups copied off it (H-03)
repo="$(value PGBACKREST_REPO1_TYPE)"
case "$repo" in
  s3|gcs|azure|sftp) ;;
  "") [ -n "$(value PGBACKREST_REPO1_HOST)" ] || gap "PGBACKREST_REPO1_TYPE is not set: WAL is archived to object storage (s3, gcs, azure), sftp or a repository host" ;;
  *) [ -n "$(value PGBACKREST_REPO1_HOST)" ] || gap "PGBACKREST_REPO1_TYPE=$repo keeps WAL on this host: use object storage, sftp or a repository host" ;;
esac
[ -n "$(value PGBACKREST_REPO1_CIPHER_PASS)" ] || gap "PGBACKREST_REPO1_CIPHER_PASS is missing: the repository is encrypted"
[ -n "$(value MASSLAK_BACKUP_OFFSITE)" ] || gap "MASSLAK_BACKUP_OFFSITE is missing: every backup is copied off this server before an update"
case "$(value MASSLAK_BACKUP_AGE_RECIPIENT)" in age1*) ;; *) gap "MASSLAK_BACKUP_AGE_RECIPIENT is missing: backups are written encrypted" ;; esac

# the release's signed images (H-08): IMAGES names them by digest, cosign checks their signatures before they run
command -v cosign >/dev/null || gap "cosign is not installed: a production server checks the signature of every image it runs (https://docs.sigstore.dev/cosign/system_config/installation/)"
images="${MASSLAK_IMAGES:-IMAGES}"; case "$images" in /*) ;; *) images="../../$images" ;; esac
[ -s "$images" ] || gap "IMAGES is missing: a production server installs and updates from a signed release archive, whose IMAGES names the signed images (RUNBOOKS.md, section 19)"
key="$(value MASSLAK_IMAGE_KEY)"
[ -z "$key" ] || [ -s "$key" ] || gap "MASSLAK_IMAGE_KEY names $key, which does not exist"

# TLS to the database (H-05)
for f in ca.crt server.crt server.key masslak_cdc.crt masslak_cdc.key; do
  [ -s "tls/$f" ] || gap "deploy/production/tls/$f is missing: run deploy/production/init.sh"
done
if [ -s tls/server.crt ]; then
  openssl x509 -checkend $((30 * 86400)) -noout -in tls/server.crt >/dev/null 2>&1 \
    || gap "the database's certificate expires within 30 days: renew it (RUNBOOKS.md, section 31)"
fi

# monitoring and alerting reach the people on call (H-07)
for r in page ticket deadman; do
  url="$(cat "secrets/${r}_webhook_url" 2>/dev/null || true)"
  case "$url" in ""|*replace-with-the-*) gap "deploy/production/secrets/${r}_webhook_url is a placeholder: put the ${r} receiver's address there" ;; esac
done
[ -s secrets/metrics_token ] || gap "deploy/production/secrets/metrics_token is missing: run deploy/production/init.sh"

# where the database runs (H-01): on two hosts with automatic failover, or on this one host as the owner accepted
case "$(value MASSLAK_DB_LAYOUT)" in
  ha)
    IFS=, read -r -a dbh <<< "$(value MASSLAK_DB_HOSTS)"
    [ "${#dbh[@]}" = 2 ] || gap "MASSLAK_DB_HOSTS must hold the two database hosts' private IPv4 addresses (MASSLAK_DB_LAYOUT=ha)"
    [ -n "$(value MASSLAK_DB_WITNESS)" ] || gap "MASSLAK_DB_WITNESS is missing: this server's private address, where the third etcd member listens"
    { [ -s tls/cluster.crt ] && [ -s tls/cluster.key ]; } || gap "deploy/production/tls/cluster.crt is missing: run deploy/production/init.sh"
    if [ "${#dbh[@]}" = 2 ] && [ -s tls/ca.crt ]; then
      # both hosts answer over TLS: one is the primary, the other its synchronous standby
      code() { curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 --cacert tls/ca.crt "https://$1:8008$2" || true; }
      primaries=0 syncs=0
      for h in "${dbh[@]}"; do
        [ "$(code "$h" /primary)" = 200 ] && primaries=$((primaries + 1))
        [ "$(code "$h" /sync)" = 200 ] && syncs=$((syncs + 1))
      done
      [ "$primaries" = 1 ] || gap "the database hosts show $primaries primaries, not one: install each with its bundle (deploy/production/ha/bundles/db1.tar.gz for ${dbh[0]}, db2.tar.gz for ${dbh[1]}): deploy/production/ha/install-db-host.sh, HIGH_AVAILABILITY.md"
      [ "$primaries" != 1 ] || [ "$syncs" -ge 1 ] || gap "no database host is a synchronous standby: a failover now could lose committed writes"
    fi ;;
  ""|single)
    [ -n "$(value MASSLAK_SINGLE_HOST_ACCEPTED)" ] || gap "the database runs on this one host (MASSLAK_DB_LAYOUT is not ha): put it on two hosts with automatic failover (MASSLAK_DB_LAYOUT=ha, HIGH_AVAILABILITY.md), or record the owner's acceptance of one host, who and when, in MASSLAK_SINGLE_HOST_ACCEPTED: losing this host then means a restore of about 30 minutes, not a failover of under a minute" ;;
  *) gap "MASSLAK_DB_LAYOUT must be ha (two database hosts) or single" ;;
esac

# every compose command uses the production profile
case "$(value COMPOSE_FILE)" in *deploy/production/docker-compose.production.yml*) ;;
  *) gap "COMPOSE_FILE in deploy/.env does not name the production profile: run deploy/production/init.sh" ;; esac

if [ "${#gaps[@]}" -gt 0 ]; then
  echo "production preflight refused (deploy/.env, deploy/production):" >&2
  printf '  - %s\n' "${gaps[@]}" >&2
  exit 1
fi
echo "production preflight (host): key service, off-host archiving and backups, TLS files, alert receivers, database layout ($(value MASSLAK_DB_LAYOUT | grep . || echo single)) in place"
