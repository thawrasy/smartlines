#!/usr/bin/env bash
# Prepares a production installation against the stand-ins of stand-ins.yml (CI and rehearsals only): fills deploy/.env
# with the key service, pgBackRest's repository, off-site backups and the alert receivers, issues the object store's
# certificate from the internal authority, starts the stand-ins, and creates the transit key in Vault. It stands for the
# release workflow too: a local registry, the three images built once, pushed and signed with a key made here, and the
# IMAGES file naming them (H-08). Then deploy/install.sh installs as on a real production server, checking those
# signatures. Run as root from the repository, after deploy/init-env.sh; needs cosign and syft.
# With MASSLAK_DB_LAYOUT=ha already in deploy/.env (job "Production with two database hosts"), the object store for WAL
# is also published on the witness address, where the database hosts reach it under its name (s3 in /etc/hosts);
# otherwise the job's single host is recorded as accepted (MASSLAK_SINGLE_HOST_ACCEPTED, H-01).
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
if grep -q '^MASSLAK_DB_LAYOUT=ha$' "$env"; then
  witness="$(sed -n 's/^MASSLAK_DB_WITNESS=//p' "$env" | tail -1)"
  put MASSLAK_CI_S3_PUBLISH "$witness:8443"
  grep -q ' s3$' /etc/hosts || echo "$witness s3" >> /etc/hosts
else
  put MASSLAK_SINGLE_HOST_ACCEPTED "CI job Production installation: one host by design, $(date -u +%F)"
  # the telemetry database too, over TLS like the primary (reviews of release 1.49.0)
  put MASSLAK_TELEMETRY_OWNER_PASSWORD "$(rand)"
  put MASSLAK_TELEMETRY_PASSWORD "$(rand)"
  put MASSLAK_TELEMETRY_UPKEEP_PASSWORD "$(rand)"
  put MASSLAK_COMPOSE_EXTRA deploy/production/ci/stand-ins.yml:deploy/telemetry/docker-compose.telemetry.yml
fi
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
# the stand-ins start before deploy/install.sh writes the release's tag; compose still reads every service's image
dc="env MASSLAK_IMAGE_TAG=ci docker compose --env-file $env"
$dc up -d vault s3 sink
for _ in $(seq 1 60); do [ -s "$ci/vault-tls/vault-ca.pem" ] && break; sleep 1; done
cp "$ci/vault-tls/vault-ca.pem" deploy/production/trust/vault-ca.crt; chmod 0644 deploy/production/trust/vault-ca.crt
v() { $dc exec -T -e VAULT_ADDR=https://127.0.0.1:8200 -e VAULT_CACERT=/vault/tls/vault-ca.pem -e VAULT_TOKEN="$token" vault vault "$@"; }
for _ in $(seq 1 60); do v status >/dev/null 2>&1 && break; sleep 1; done
v secrets enable transit >/dev/null
v write -f transit/keys/masslak-field >/dev/null

# the release workflow's part (H-08): images built once, pushed to a registry and signed; the server verifies them
docker rm -f masslak-ci-registry >/dev/null 2>&1 || true
docker run -d --name masslak-ci-registry -p 127.0.0.1:5000:5000 \
  registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e >/dev/null
for _ in $(seq 1 30); do curl -sf http://127.0.0.1:5000/v2/ >/dev/null && break; sleep 1; done
keys=/etc/masslak/ci-release; mkdir -p "$keys"; chmod 0700 "$keys"
[ -s "$keys/ci-release.key" ] || (cd "$keys" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix ci-release >/dev/null 2>&1)
put MASSLAK_IMAGE_KEY "$keys/ci-release.pub"
put MASSLAK_IMAGE_REGISTRY_HTTP true
./deploy/images.sh build 127.0.0.1:5000 ci "$(git rev-parse HEAD)" IMAGES
COSIGN_KEY="$keys/ci-release.key" COSIGN_PASSWORD="" ./deploy/images.sh sign IMAGES
echo "stand-ins ready: Vault (transit key masslak-field), object storage, alert sink, signed images in a registry"
