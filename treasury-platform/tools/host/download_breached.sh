#!/usr/bin/env bash
# The leaked-password list of the host (DQ-S04-1, ADR 0053): one file per SHA-1 prefix, <PREFIX>.txt holding
# "SUFFIX:COUNT" lines, the layout BankFas.Core.Security.BreachedPasswords reads. It asks the public range API of
# Have I Been Pwned for each of the 1,048,576 prefixes (k-anonymity: only prefixes leave the host), 4 at a time (the API resets connections from a host that asks more), and
# keeps what it already has, so a stopped run resumes. About 30 GB; refresh it monthly and point
# Passwords__BreachedList__Directory at it (tools/host/compose.yml mounts /srv/bankfas/breached).
#
# Usage: download_breached.sh <directory> [parallel]
set -euo pipefail
DIR="${1:?the target directory}"
PAR="${2:-4}"
mkdir -p "$DIR"
export DIR
fetch() {
    local p="$1" f="$DIR/$1.txt"
    [ -s "$f" ] && return 0
    curl -fsS --retry 5 --retry-delay 2 --retry-all-errors -A "BankFas-breached-list" "https://api.pwnedpasswords.com/range/$p" -o "$f.part" && mv "$f.part" "$f"
}
export -f fetch
printf '%05X\n' $(seq 0 1048575) | xargs -P "$PAR" -I{} bash -c 'fetch {}'
n=$(find "$DIR" -name '?????.txt' | wc -l)
[ "$n" -eq 1048576 ] || { echo "only $n of 1048576 ranges: run it again"; exit 1; }
echo "leaked-password list complete: $n ranges in $DIR"
