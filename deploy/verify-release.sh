#!/usr/bin/env bash
# Verifies a release archive before it is extracted on a server (expert review of October 2026, stage C6):
#   ./deploy/verify-release.sh masslak-v1.2.3.tar.gz
# Keep next to the archive what the GitHub release carries: SHA256SUMS, masslak-v1.2.3.spdx.json and the
# .sigstore.json bundles. The script checks that the archive and the checksums were signed by the release workflow of
# this repository for a v* tag (keyless Sigstore, needs cosign), that the archive and its bill of materials match the
# checksums, and prints the commit recorded inside, which the release manifest (1058) then records.
set -euo pipefail
archive="${1:?usage: deploy/verify-release.sh <masslak-vX.Y.Z.tar.gz>}"
dir="$(cd "$(dirname "$archive")" && pwd)"
base="$(basename "$archive")"
name="${base%.tar.gz}"
repo="${MASSLAK_RELEASE_REPO:-thawrasy/smartlines}"
fail() { echo "release check failed: $*" >&2; exit 1; }
command -v cosign >/dev/null || { echo "cosign is needed: https://docs.sigstore.dev/cosign/system_config/installation/" >&2; exit 2; }
for f in SHA256SUMS "$base"; do
  [ -f "$dir/$f.sigstore.json" ] || fail "$f.sigstore.json is missing next to the archive"
  cosign verify-blob --bundle "$dir/$f.sigstore.json" \
    --certificate-identity-regexp "^https://github\.com/${repo}/\.github/workflows/release\.yml@refs/tags/v" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com "$dir/$f" >/dev/null 2>&1 \
    || fail "$f is not signed by the release workflow of $repo"
done
(cd "$dir" && grep -E "  (${base}|${name}\.spdx\.json)\$" SHA256SUMS | sha256sum --strict -c - >/dev/null) \
  || fail "the archive or its bill of materials does not match SHA256SUMS"
[ "$(cd "$dir" && grep -cE "  (${base}|${name}\.spdx\.json)\$" SHA256SUMS)" = 2 ] || fail "SHA256SUMS does not list both files"
tar -xOzf "$archive" "$name/RELEASE" || fail "the archive has no RELEASE record"
echo "OK: $base is a signed release of $repo"
