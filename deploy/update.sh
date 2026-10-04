#!/usr/bin/env bash
# Updates a running server to the latest code: backup first, then rebuild and restart. The migrate service
# applies any new schema files before the new API starts, and the old containers keep serving until then.
#   ./deploy/update.sh [git ref, default: the current branch]
set -euo pipefail
cd "$(dirname "$0")/.."
ref="${1:-}"
compose() { docker compose --env-file deploy/.env "$@"; }
./deploy/backup.sh
git fetch --quiet origin
if [ -n "$ref" ]; then git checkout --quiet "$ref"; fi
git pull --quiet --ff-only || true
echo "deploying $(git log -1 --format='%h %s')"
compose build
compose up -d
compose ps
docker image prune -f >/dev/null
curl -fsS "https://${MASSLAK_DOMAIN:-$(grep ^MASSLAK_DOMAIN= deploy/.env | cut -d= -f2)}/api/health" && echo " healthy"
