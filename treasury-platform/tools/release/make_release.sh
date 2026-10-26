#!/usr/bin/env bash
# The release package of BankFas (docs/57): the two images in one file (their common layers once), the install kit
# (the deployment tools and the database scripts, without the documents), the documents in a file of their own to keep
# apart from the server, the install guide (docs/62) and the release notes (docs/57), and the SHA-256 of every file
# (DQ-S11-4). The images job
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
docker save "bankfas-api:$VERSION" "bankfas-worker:$VERSION" | gzip -6 > "$OUT/bankfas-images-$VERSION.tar.gz"

# The release's own files, from the commit it is built from (nothing uncommitted).
COMMIT="$(git rev-parse HEAD)"
# From the repository root: run in treasury-platform/, git archive would keep only that folder's path inside the tree.
TOP="$(git rev-parse --show-toplevel)"
git -C "$TOP" archive --format=tar.gz --prefix="treasury-platform/" -o "$OUT/bankfas-kit-$VERSION.tar.gz" \
    "$COMMIT" -- treasury-platform ':(exclude)treasury-platform/docs'
tar -tzf "$OUT/bankfas-kit-$VERSION.tar.gz" | grep -q '^treasury-platform/tools/deploy/deploy.sh$' || { echo "the install kit has no tools" >&2; exit 1; }
! tar -tzf "$OUT/bankfas-kit-$VERSION.tar.gz" | grep -q '^treasury-platform/docs/' || { echo "the install kit has the documents" >&2; exit 1; }
git -C "$TOP" archive --format=tar.gz --prefix="bankfas-docs-$VERSION/" -o "$OUT/bankfas-docs-$VERSION.tar.gz" "$COMMIT:treasury-platform/docs"
# The install guide and the notes are written for the release they ship with: their commands name this version's files.
for d in docs/57-release.md docs/62-private-trial-by-ip.md; do
    grep -q "bankfas-images-$VERSION.tar.gz" "$d" || { echo "$d is not written for $VERSION" >&2; exit 2; }
done
cp docs/62-private-trial-by-ip.md "$OUT/INSTALL-AR.md"
cp docs/62-PRIVATE-TRIAL-BY-IP.docx "$OUT/INSTALL-AR.docx"
cp docs/57-release.md "$OUT/RELEASE-NOTES-AR.md"
{
    echo "BankFas $VERSION"
    echo "commit: $COMMIT"
    echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "api image: $(docker image inspect --format '{{.Id}}' "bankfas-api:$VERSION")"
    echo "worker image: $(docker image inspect --format '{{.Id}}' "bankfas-worker:$VERSION")"
} > "$OUT/VERSION.txt"
(cd "$OUT" && sha256sum -- * > SHA256SUMS)
# The one file to take to the server (docs/62): everything above but the documents, in a folder of the version, with
# its own SHA-256 beside it. The documents stay a file of their own, to keep on a computer or a drive.
STAGE="$(mktemp -d)"; mkdir "$STAGE/bankfas-$VERSION"
(cd "$OUT" && cp -- $(ls | grep -v "^bankfas-docs-$VERSION.tar.gz$") "$STAGE/bankfas-$VERSION/")
tar -C "$STAGE" -cf "$OUT/bankfas-$VERSION-server.tar" "bankfas-$VERSION"
rm -rf "$STAGE"
(cd "$OUT" && sha256sum "bankfas-$VERSION-server.tar" > "bankfas-$VERSION-server.tar.sha256")
ls -la "$OUT"
