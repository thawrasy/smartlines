#!/usr/bin/env bash
# The release package of BankFas (docs/57): the two images as files, the source of the release (the deployment tools,
# the database scripts and the documents), the install guide, and the SHA-256 of every file (DQ-S11-4). The images job
# of the CI builds it from the images its pilot run just tested, and publishes it as a GitHub release when the commit
# message says [release]; it runs the same way on any machine with Docker and git.
#
# Usage: tools/release/make_release.sh <version> <api image> <worker image> <out dir>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION="${1:?version, e.g. $(cat RELEASE)}"; API="${2:?api image}"; WORKER="${3:?worker image}"; OUT="${4:?out dir}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "the version is three numbers, like 1.0.0" >&2; exit 2; }
[ "$VERSION" = "$(cat RELEASE)" ] || { echo "the version is not the one in RELEASE ($(cat RELEASE))" >&2; exit 2; }
mkdir -p "$OUT"
[ -z "$(ls -A "$OUT")" ] || { echo "$OUT is not empty" >&2; exit 2; }

# The images under the names the host's compose.yml takes when there is no registry (docs/54 R-02).
docker tag "$API" "bankfas-api:$VERSION"
docker tag "$WORKER" "bankfas-worker:$VERSION"
docker save "bankfas-api:$VERSION" | gzip -6 > "$OUT/bankfas-api-$VERSION.tar.gz"
docker save "bankfas-worker:$VERSION" | gzip -6 > "$OUT/bankfas-worker-$VERSION.tar.gz"

# The release's own files, from the commit it is built from (nothing uncommitted).
COMMIT="$(git rev-parse HEAD)"
# From the repository root: run in treasury-platform/, git archive would keep only that folder's path inside the tree.
git -C "$(git rev-parse --show-toplevel)" archive --format=tar.gz --prefix="treasury-platform/" -o "$OUT/bankfas-source-$VERSION.tar.gz" \
    "$COMMIT:treasury-platform"
[ "$(tar -tzf "$OUT/bankfas-source-$VERSION.tar.gz" | grep -c '^treasury-platform/tools/deploy/deploy.sh$')" = 1 ] || { echo "the source archive has no tools" >&2; exit 1; }
cp docs/57-release-1.0.0.md "$OUT/INSTALL-AR.md"
cp docs/57-RELEASE-1.0.0.docx "$OUT/INSTALL-AR.docx"
{
    echo "BankFas $VERSION"
    echo "commit: $COMMIT"
    echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "api image: $(docker image inspect --format '{{.Id}}' "bankfas-api:$VERSION")"
    echo "worker image: $(docker image inspect --format '{{.Id}}' "bankfas-worker:$VERSION")"
} > "$OUT/VERSION.txt"
(cd "$OUT" && sha256sum -- * > SHA256SUMS)
ls -la "$OUT"
