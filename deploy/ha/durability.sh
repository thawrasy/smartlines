#!/usr/bin/env bash
# Zero data loss as a setting, for the Patroni cluster (owner's decision 1; review of release 1.47.0, R-39).
#   MASSLAK_ZERO_DATA_LOSS=on   synchronous_mode with synchronous_mode_strict: a commit waits for a synchronous standby;
#                               if none is left, commits wait instead of being confirmed by the primary alone.
#   MASSLAK_ZERO_DATA_LOSS=off  synchronous_mode without strict: Patroni drops to asynchronous when the standby is gone.
# Run on one database server of the main site, as the user that runs Patroni:
#   MASSLAK_ZERO_DATA_LOSS=on ./deploy/ha/durability.sh [/etc/patroni/patroni.yml]
set -euo pipefail
config="${1:-/etc/patroni/patroni.yml}"
case "${MASSLAK_ZERO_DATA_LOSS:-}" in
  on)  strict=true ;;
  off) strict=false ;;
  *) echo "set MASSLAK_ZERO_DATA_LOSS to on or off" >&2; exit 2 ;;
esac
patronictl -c "$config" edit-config --force --set synchronous_mode=true --set synchronous_mode_strict="$strict" \
           --pg synchronous_commit=on
patronictl -c "$config" show-config | grep -E 'synchronous_mode(_strict)?:'
patronictl -c "$config" list
