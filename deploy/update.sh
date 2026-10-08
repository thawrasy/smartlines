#!/usr/bin/env bash
# Updates a running server to the latest code: backup first, then rebuild and restart. The migrate service
# applies any new schema files before the new API starts, and the old containers keep serving until then.
#   ./deploy/update.sh [git ref, default: the current branch] [--sha <commit id approved for release>]
# Installed from a release archive instead of git: extract the new archive over this directory first (deploy/.env
# is not in the archive and stays as it is), then run this script; it rebuilds from the files on disk.
#
# The code is settled before anything changes (review of October 2026, stage A3): a fetch or pull that fails, a
# branch that has diverged from the remote, local edits to tracked files, or a commit other than the one given with
# --sha (or MASSLAK_EXPECTED_SHA) stops the update while the running version keeps serving. The deployed commit is
# written to deploy/DEPLOYED, and the update ends only when /api/ready answers.
set -euo pipefail
cd "$(dirname "$0")/.."
ref="" expected="${MASSLAK_EXPECTED_SHA:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) expected="${2:?--sha needs a commit id}"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) ref="$1"; shift ;;
  esac
done
compose() { docker compose --env-file deploy/.env "$@"; }
fail() { echo "update stopped: $*" >&2; exit 1; }
if [ -d .git ]; then
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "tracked files were edited on this server (git status)"
  git fetch --quiet --tags origin || fail "git fetch failed"
  if [ -n "$ref" ]; then git checkout --quiet "$ref" || fail "cannot check out $ref"; fi
  if git symbolic-ref -q HEAD >/dev/null; then              # on a branch: take the remote's commits, never merge
    git pull --quiet --ff-only || fail "git pull failed or the branch has diverged from origin"
    upstream="$(git rev-parse -q --verify '@{upstream}' || true)"
    [ -z "$upstream" ] || [ "$(git rev-parse HEAD)" = "$upstream" ] || fail "this branch has commits that are not on origin"
  fi
  sha="$(git rev-parse HEAD)"
  if [ -n "$expected" ]; then
    [ "${#expected}" -ge 12 ] || fail "--sha needs at least 12 characters of the commit id"
    case "$sha" in "$expected"*) ;; *) fail "the checked-out commit is $sha, not the approved $expected" ;; esac
  fi
  echo "deploying $(git log -1 --format='%H %s')"
else
  # a signed release archive records its commit in RELEASE (deploy/verify-release.sh checks it before extraction)
  sha="$(sed -n 's/^commit=\([0-9a-f]\{40\}\)$/\1/p' RELEASE 2>/dev/null || true)"
  sha="${sha:-release-archive}"
  if [ -n "$expected" ]; then
    [ "${#expected}" -ge 12 ] || fail "--sha needs at least 12 characters of the commit id"
    case "$sha" in "$expected"*) ;; *) fail "this release archive is of commit $sha, not the approved $expected" ;; esac
  fi
  echo "deploying the files in $(pwd) (release archive, no git checkout)"
fi
./deploy/backup.sh
# secrets added by newer releases (existing values are never changed)
if ! grep -q '^MASSLAK_REPLICATION_PASSWORD=.' deploy/.env; then
  sed -i '/^MASSLAK_REPLICATION_PASSWORD=/d' deploy/.env
  echo "MASSLAK_REPLICATION_PASSWORD=$(openssl rand -hex 24)" >> deploy/.env
  echo "added MASSLAK_REPLICATION_PASSWORD (read replica) to deploy/.env"
fi
MASSLAK_RELEASE_COMMIT="$sha" compose build        # the release manifest (1058) records the commit
compose up -d
compose ps
docker image prune -f >/dev/null
domain="${MASSLAK_DOMAIN:-$(grep ^MASSLAK_DOMAIN= deploy/.env | cut -d= -f2)}"
tls=(); [ "$domain" = localhost ] && tls=(-k)                # a local trial uses Caddy's own certificate authority
for i in $(seq 1 60); do
  curl -fsS "${tls[@]}" --resolve "$domain:443:127.0.0.1" "https://$domain/api/ready" >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { compose logs --tail 80 migrate app; fail "the new version is not ready (https://$domain/api/ready)"; }
  sleep 3
done
printf '%s %s\n' "$sha" "$(date -u +%FT%TZ)" >> deploy/DEPLOYED
echo "ready: $sha"
