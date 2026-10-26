#!/usr/bin/env bash
# Signed images (reviews of October 2026, H-08). The API, egress proxy and production database images are built once,
# in CI, pushed to a registry and signed there; a production server runs exactly those, by digest, after checking the
# signatures, and never builds its own.
#
#   ./deploy/images.sh build PREFIX VERSION COMMIT IMAGES   build the three images, push them, write IMAGES
#   ./deploy/images.sh sign IMAGES                          sign each digest and attest its bill of materials (SPDX)
#   ./deploy/images.sh verify IMAGES                        check every signature and bill of materials
#   ./deploy/images.sh pull IMAGES TAG                      verify, pull by digest, tag NAME:TAG for docker compose
#
# IMAGES holds commit=, version= and NAME=REGISTRY/NAME@sha256:... for masslak, masslak-egress and masslak-db. The
# release workflow writes it into the release archive, which is itself signed (deploy/verify-release.sh): the archive
# names the exact images that go with its files. deploy/install.sh and deploy/update.sh pull them on a production server.
#
# Verification is keyless by default: each image must be signed by this repository's release workflow for a v* tag
# (Sigstore, recorded in its transparency log), and so must its bill of materials. MASSLAK_IMAGE_KEY names a cosign
# public key instead, for images signed with a key (a private registry; CI); MASSLAK_IMAGE_REGISTRY_HTTP=true allows a
# registry without TLS (CI only). Both may be set in deploy/.env. Signing uses the key file COSIGN_KEY when set, else the
# keyless identity of the workflow that runs it. The bill of materials comes from syft. MASSLAK_IMAGE_NAMES limits
# verify and pull to some of the images: a database host of the layout with two (H-01) runs masslak-db only.
set -euo pipefail
cd "$(dirname "$0")/.."
ALL="masslak masslak-egress masslak-db"
NAMES="${MASSLAK_IMAGE_NAMES:-$ALL}"
fail() { echo "images: $*" >&2; exit 1; }
env_value() { [ -f deploy/.env ] && sed -n "s/^$1=//p" deploy/.env | tail -1 || true; }
key="${MASSLAK_IMAGE_KEY:-$(env_value MASSLAK_IMAGE_KEY)}"
http="${MASSLAK_IMAGE_REGISTRY_HTTP:-$(env_value MASSLAK_IMAGE_REGISTRY_HTTP)}"
repo="${MASSLAK_RELEASE_REPO:-thawrasy/smartlines}"
registry=()
[ "$http" = true ] && registry=(--allow-http-registry --allow-insecure-registry)
if [ -n "$key" ]; then
  trust=(--key "$key" --insecure-ignore-tlog=true)
  signer="the key $key"
else
  trust=(--certificate-identity-regexp "^https://github\.com/${repo}/\.github/workflows/release\.yml@refs/tags/v"
         --certificate-oidc-issuer https://token.actions.githubusercontent.com)
  signer="the release workflow of $repo"
fi
ref_of() { sed -n "s/^$1=//p" "$2" | tail -1; }
need() { command -v "$1" >/dev/null || fail "$1 is needed ($2)"; }

check_file() {                             # every image named, each by its digest
  local name ref
  [ -f "$1" ] || fail "$1 is missing: a production server runs the signed images a release names (RUNBOOKS.md, section 19)"
  for name in $NAMES; do
    ref="$(ref_of "$name" "$1")"
    [[ "$ref" =~ ^[a-z0-9.:/_-]+/$name@sha256:[0-9a-f]{64}$ ]] || fail "$1 names no $name image by its digest"
  done
}

verify() {
  local name ref out
  check_file "$1"
  need cosign "https://docs.sigstore.dev/cosign/system_config/installation/"
  for name in $NAMES; do
    ref="$(ref_of "$name" "$1")"
    out="$(cosign verify "${trust[@]}" "${registry[@]}" "$ref" 2>&1 >/dev/null)" \
      || fail "$name ($ref) is not signed by $signer: $(printf '%s' "$out" | tail -1)"
    out="$(cosign verify-attestation "${trust[@]}" "${registry[@]}" --type spdxjson "$ref" 2>&1 >/dev/null)" \
      || fail "$name ($ref) has no bill of materials signed by $signer: $(printf '%s' "$out" | tail -1)"
    echo "verified $name: $ref"
  done
}

case "${1:-}" in
  build)
    prefix="${2:?prefix}" version="${3:?version}" commit="${4:?commit}" out="${5:?IMAGES file}"
    build() {                              # quiet when it works, the end of the build's log when it does not
      local log; log="$(mktemp)"
      if ! docker build --progress=plain "$@" > "$log" 2>&1; then tail -n 80 "$log" >&2; rm -f "$log"; fail "could not build ${*: -1}"; fi
      rm -f "$log"
    }
    build --build-arg MASSLAK_RELEASE_COMMIT="$commit" -t "$prefix/masslak:$version" .
    build -t "$prefix/masslak-egress:$version" deploy/egress
    build --build-context guard-src=db/guard -t "$prefix/masslak-db:$version" deploy/production/db   # with the settings guard (db/guard)
    printf 'commit=%s\nversion=%s\n' "$commit" "$version" > "$out"
    for name in $ALL; do
      docker push -q "$prefix/$name:$version" >/dev/null
      digest="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$prefix/$name:$version" | grep -m1 "^$prefix/$name@")"
      echo "$name=$digest" >> "$out"
    done
    cat "$out" ;;
  sign)
    NAMES="$ALL"
    check_file "${2:?IMAGES file}"
    need cosign "https://docs.sigstore.dev/cosign/system_config/installation/"
    need syft "https://github.com/anchore/syft"
    sign=(--yes)
    [ -z "${COSIGN_KEY:-}" ] || sign+=(--key "$COSIGN_KEY" --use-signing-config=false --tlog-upload=false)
    for name in $NAMES; do
      ref="$(ref_of "$name" "$2")"
      cosign sign "${sign[@]}" "${registry[@]}" "$ref" 2>/dev/null
      sbom="$(mktemp)"
      SYFT_REGISTRY_INSECURE_USE_HTTP="$([ "$http" = true ] && echo true || echo false)" syft -q "registry:$ref" -o "spdx-json=$sbom"
      cosign attest "${sign[@]}" "${registry[@]}" --type spdxjson --predicate "$sbom" "$ref" 2>/dev/null
      rm -f "$sbom"
      echo "signed $name and its bill of materials: $ref"
    done ;;
  verify)
    verify "${2:?IMAGES file}" ;;
  pull)
    images="${2:?IMAGES file}" tag="${3:?tag}"
    verify "$images"
    for name in $NAMES; do
      ref="$(ref_of "$name" "$images")"
      docker pull -q "$ref" >/dev/null || fail "cannot pull $ref"
      docker tag "$ref" "$name:$tag"
    done
    echo "the signed images of $(ref_of version "$images") ($(ref_of commit "$images" | cut -c1-12)) are tagged $tag" ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
