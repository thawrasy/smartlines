#!/usr/bin/env bash
# Prepares a production installation against the stand-ins of stand-ins.yml (CI and rehearsals only): fills deploy/.env
# with the key service, pgBackRest's repository, off-site backups and the alert receivers, issues the object store's
# certificate from the internal authority, starts the stand-ins, and creates the transit key in Vault. Then
# deploy/install.sh installs as on a real production server. Run as root from the repository, after deploy/init-env.sh.
set -euo pipefail
cd "$(dirname "$0")/../../.."
env=deploy/.env
[ -f "$env" ] || { echo "run deploy/init-env.sh first" >&2; exit 1; }
put() { if grep -q "^$1=" "$env"; then sed -i "s|^$1=.*|$1=$2|" "$env"; else echo "$1=$2" >> "$env"; fi; }
rand() { openssl rand -hex 16; }
offsite="${MASSLAK_CI_OFFSITE:-/tmp/masslak-offsite}"; mkdir -p "$offsite"
age_key="${MASSLAK_CI_AGE_KEY:-/tmp/masslak-backup.key}"
[ -s "$age_key" ] || age-keygen -o "$age_key" 2>/dev/null
token="ci-vault-$(rand)"
s3_secret="ci-s3-$(rand)"
put MASSLAK_KMS_PROVIDER vault
put MASSLAK_VAULT_ADDR https://vault:8200
put MASSLAK_VAULT_TOKEN "$token"
put MASSLAK_VAULT_TRANSIT_KEY masslak-field
put MASSLAK_VAULT_CA_FILE /etc/masslak/trust/vault-ca.crt
put PGBACKREST_REPO1_TYPE s3
put PGBACKREST_REPO1_PATH /pgbackrest
put PGBACKREST_REPO1_S3_BUCKET masslak-wal
put PGBACKREST_REPO1_S3_ENDPOINT s3
put PGBACKREST_REPO1_S3_REGION us-east-1
put PGBACKREST_REPO1_S3_KEY masslak-wal
put PGBACKREST_REPO1_S3_KEY_SECRET "$s3_secret"
put PGBACKREST_REPO1_S3_URI_STYLE path
put PGBACKREST_REPO1_STORAGE_PORT 8443
put PGBACKREST_REPO1_STORAGE_CA_FILE /var/lib/postgresql/tls/ca.crt
put PGBACKREST_REPO1_CIPHER_PASS "$(rand)"
put MASSLAK_BACKUP_OFFSITE "$offsite"
put MASSLAK_BACKUP_AGE_RECIPIENT "$(age-keygen -y "$age_key")"
put MASSLAK_WAREHOUSE_ADDRESS 192.0.2.10/32
put MASSLAK_COMPOSE_EXTRA deploy/production/ci/stand-ins.yml
./deploy/production/init.sh
for r in page ticket deadman; do echo "http://sink:8080/$r" > "deploy/production/secrets/${r}_webhook_url"; done

# the object store's certificate, from the internal authority, and its one identity
ci=deploy/production/ci; tls=deploy/production/tls
openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -subj /CN=s3 -keyout "$ci/s3.key" -out "$ci/s3.csr" 2>/dev/null
printf 'subjectAltName=DNS:s3\nextendedKeyUsage=serverAuth\n' > "$ci/s3.ext"
openssl x509 -req -in "$ci/s3.csr" -CA "$tls/ca.crt" -CAkey "$tls/ca.key" -CAcreateserial -days 30 -extfile "$ci/s3.ext" -out "$ci/s3.crt" 2>/dev/null
rm -f "$ci/s3.csr" "$ci/s3.ext"; chmod 0644 "$ci/s3.key" "$ci/s3.crt"
printf '{"identities":[{"name":"masslak-wal","credentials":[{"accessKey":"masslak-wal","secretKey":"%s"}],"actions":["Read","Write","List","Tagging","Admin"]}]}' "$s3_secret" > "$ci/s3.json"
chmod 0644 "$ci/s3.json"
mkdir -p "$ci/vault-tls"; rm -f "$ci"/vault-tls/*; chmod 0777 "$ci/vault-tls"

./deploy/env-split.sh
dc="docker compose --env-file $env"
$dc up -d vault s3 sink
for _ in $(seq 1 60); do [ -s "$ci/vault-tls/vault-ca.pem" ] && break; sleep 1; done
cp "$ci/vault-tls/vault-ca.pem" deploy/production/trust/vault-ca.crt; chmod 0644 deploy/production/trust/vault-ca.crt
v() { $dc exec -T -e VAULT_ADDR=https://127.0.0.1:8200 -e VAULT_CACERT=/vault/tls/vault-ca.pem -e VAULT_TOKEN="$token" vault vault "$@"; }
for _ in $(seq 1 60); do v status >/dev/null 2>&1 && break; sleep 1; done
v secrets enable transit >/dev/null
v write -f transit/keys/masslak-field >/dev/null
echo "stand-ins ready: Vault (transit key masslak-field), object storage, alert sink"
