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
#
# Images are tagged with the commit they were built from, never only "latest" (code review of October 2026, H-07):
# deploy/.env records MASSLAK_IMAGE_TAG (running) and MASSLAK_PREVIOUS_IMAGE_TAG (the one before), and both stay on the
# server. An update that does not become ready goes back to the previous images by itself, and
#   ./deploy/update.sh --rollback
# restarts the API and the worker on the previous images at any time, without rebuilding. Schema files only move
# forward and are written so the previous release still runs on them (expand, then contract: db/README.md), so a
# rollback leaves the database as it is.
set -euo pipefail
cd "$(dirname "$0")/.."
ref="" expected="${MASSLAK_EXPECTED_SHA:-}" rollback=false
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) expected="${2:?--sha needs a commit id}"; shift 2 ;;
    --rollback) rollback=true; shift ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) ref="$1"; shift ;;
  esac
done
compose() { docker compose --env-file deploy/.env "$@"; }
fail() { echo "update stopped: $*" >&2; exit 1; }
env_value() { { sed -n "s/^$1=//p" deploy/.env 2>/dev/null || true; } | tail -1; }
set_env() { if grep -q "^$1=" deploy/.env; then sed -i "s|^$1=.*|$1=$2|" deploy/.env; else echo "$1=$2" >> deploy/.env; fi; }
ready() {                                                    # /api/ready through Caddy, for up to $1 tries 3 s apart
  domain="${MASSLAK_DOMAIN:-$(env_value MASSLAK_DOMAIN)}"
  tls=(); [ "$domain" = localhost ] && tls=(-k)              # a local trial uses Caddy's own certificate authority
  for i in $(seq 1 "$1"); do
    curl -fsS "${tls[@]}" --resolve "$domain:443:127.0.0.1" "https://$domain/api/ready" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}
# the API and the worker on the images of a tag, without rebuilding and without the schema step
run_tag() { MASSLAK_IMAGE_TAG="$1" compose up -d --no-build --no-deps app worker; }

if [ "$rollback" = true ]; then
  current="$(env_value MASSLAK_IMAGE_TAG)" previous="$(env_value MASSLAK_PREVIOUS_IMAGE_TAG)"
  [ -n "$previous" ] || fail "no previous images recorded (MASSLAK_PREVIOUS_IMAGE_TAG in deploy/.env)"
  docker image inspect "masslak:$previous" >/dev/null 2>&1 || fail "the previous image masslak:$previous is not on this server"
  echo "rolling back the API and the worker from ${current:-?} to $previous"
  run_tag "$previous"
  ready 60 || { compose logs --tail 80 app; fail "the previous version is not ready either (https://$domain/api/ready)"; }
  set_env MASSLAK_IMAGE_TAG "$previous"
  [ -z "$current" ] || set_env MASSLAK_PREVIOUS_IMAGE_TAG "$current"      # a second --rollback goes forward again
  printf '%s %s rollback\n' "$previous" "$(date -u +%FT%TZ)" >> deploy/DEPLOYED
  echo "ready: images $previous (run ./deploy/update.sh --rollback again to return to ${current:-the newer images})"
  exit 0
fi
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
# secrets added by newer releases (existing values are never changed)
if ! grep -q '^MASSLAK_REPLICATION_PASSWORD=.' deploy/.env; then
  sed -i '/^MASSLAK_REPLICATION_PASSWORD=/d' deploy/.env
  echo "MASSLAK_REPLICATION_PASSWORD=$(openssl rand -hex 24)" >> deploy/.env
  echo "added MASSLAK_REPLICATION_PASSWORD (read replica) to deploy/.env"
fi
if ! grep -q '^MASSLAK_ENVIRONMENT=.' deploy/.env; then
  sed -i '/^MASSLAK_ENVIRONMENT=/d' deploy/.env
  env_name=$(grep -q '^MASSLAK_SEED_DEMO=true' deploy/.env && echo development || echo production)
  echo "MASSLAK_ENVIRONMENT=$env_name" >> deploy/.env
  echo "added MASSLAK_ENVIRONMENT=$env_name to deploy/.env (set it to staging on the staging servers)"
fi
production=false
grep -q '^MASSLAK_ENVIRONMENT=production$' deploy/.env && production=true
if [ "$production" = true ]; then
  # the production profile (reviews of October 2026, package 2): checked before anything is built or changed
  ./deploy/production/init.sh
  ./deploy/production/preflight.sh || fail "the production profile is incomplete (deploy/production/preflight.sh)"
fi
./deploy/env-split.sh                     # each container receives only its part of deploy/.env (H-06)
# The backup before the update. A copy kept on this server only (exit 3: no off-site copy) stops a production update
# (H-03): a server lost during the update would take its only backup with it. Elsewhere it is a warning, and the alert
# BackupOffsiteStale follows it.
rc=0; ./deploy/backup.sh || rc=$?
if [ "$rc" != 0 ]; then
  [ "$rc" = 3 ] || exit "$rc"
  [ "$production" = true ] && fail "the backup before this update was not copied off the server (MASSLAK_BACKUP_OFFSITE); nothing was changed"
  echo "warning: the backup before this update was not copied off the server" >&2
fi
old_tag="$(env_value MASSLAK_IMAGE_TAG)"
case "$sha" in release-archive) tag="archive-$(date -u +%Y%m%d%H%M%S)" ;; *) tag="${sha:0:12}" ;; esac
export MASSLAK_IMAGE_TAG="$tag"
MASSLAK_RELEASE_COMMIT="$sha" compose build        # the release manifest (1058) records the commit
if [ "$production" = true ]; then
  # the database side of the profile, on the database itself (TLS only, archiving proven to the off-host repository,
  # pgoutput only), before the new version starts: a refused update leaves the schema and the running version as they
  # were. The database, its replica and PgBouncer restart first only when their image or settings changed (the first
  # switch to the production profile).
  compose up -d --no-deps db db-replica pgbouncer
  for _ in $(seq 1 60); do compose exec -T db pg_isready -q 2>/dev/null && break; sleep 2; done
  compose run --rm --no-deps -T migrate sh -c \
      'export PGUSER="${POSTGRES_USER:-postgres}" PGPASSWORD="$POSTGRES_PASSWORD"; cd /app/backend && python -m app.tools.preflight' \
    || fail "the production preflight refused the database (see above); the schema and the running version are unchanged"
fi
compose up -d
compose ps
if ! ready 60; then
  compose logs --tail 80 migrate app
  if [ -n "$old_tag" ] && [ "$old_tag" != "$tag" ] && docker image inspect "masslak:$old_tag" >/dev/null 2>&1; then
    echo "the new version is not ready: back to the images $old_tag" >&2
    run_tag "$old_tag"
  fi
  fail "the new version is not ready (https://$domain/api/ready)"
fi
set_env MASSLAK_IMAGE_TAG "$tag"
[ -z "$old_tag" ] || [ "$old_tag" = "$tag" ] || set_env MASSLAK_PREVIOUS_IMAGE_TAG "$old_tag"
previous="$(env_value MASSLAK_PREVIOUS_IMAGE_TAG)"
# the durability the owner chose (MASSLAK_ZERO_DATA_LOSS, decision 1), and WAL archiving proven after the restart (R-40)
./deploy/durability.sh || echo "warning: the zero data loss setting could not be applied; run ./deploy/durability.sh" >&2
if ! ./deploy/pitr/check-archive.sh; then
  # on a production server a broken archive is a failed update, not a warning (H-02): the new version runs, but every
  # minute without archiving widens what a point-in-time restore would lose
  [ "$production" = true ] && fail "WAL archiving does not work after the update (RUNBOOKS.md, section 2)"
  echo "warning: WAL archiving does not work after the update (RUNBOOKS.md, section 2)" >&2
fi
# keep the running and the previous images, drop older ones
for name in masslak masslak-egress; do
  for t in $(docker image ls "$name" --format '{{.Tag}}'); do
    case "$t" in "$tag"|"$previous") ;; *) docker image rm "$name:$t" >/dev/null 2>&1 || true ;; esac
  done
done
docker image prune -f >/dev/null
printf '%s %s %s\n' "$sha" "$(date -u +%FT%TZ)" "$tag" >> deploy/DEPLOYED
echo "ready: $sha (images $tag; previous ${previous:-none})"
