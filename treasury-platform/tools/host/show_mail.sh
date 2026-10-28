#!/usr/bin/env bash
# The mail of the private trial without SMTP (site.conf ACCESS=ip, empty SMTP_HOST; docs/62): the messages the
# platform wrote to /srv/bankfas/mail instead of sending them, newest first, each with its addressee, subject, time and
# links (an invitation, a password reset). Give a link to its person by a channel of your own. Read only; run as root.
#
# Usage: sudo tools/host/show_mail.sh [how many, default 5] [address to filter on]
set -euo pipefail
DIR="${BANKFAS_MAIL_DIR:-/srv/bankfas/mail}"
N="${1:-5}" WHO="${2:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { echo "show_mail: the count is a number" >&2; exit 1; }
[ -d "$DIR" ] || { echo "show_mail: no $DIR: the mail is sent by SMTP on this host, or nothing was provisioned" >&2; exit 1; }
shown=0
while IFS= read -r f; do
    [ -n "$WHO" ] && ! grep -qiF "To: $WHO" "$f" && continue
    echo "------------------------------------------------------------"
    echo "file:    $(basename "$f")   ($(date -u -r "$f" '+%Y-%m-%d %H:%M UTC'))"
    # The application writes the file in UTF-8 with a byte order mark, which would hide the first header (To:).
    sed '1s/^\xEF\xBB\xBF//' "$f" | grep -m1 -i '^To:' || true
    grep -m1 -i '^Subject:' "$f" || true
    grep -oE 'https://[^ "<>]+' "$f" | sort -u | sed 's/^/link:    /' || true
    shown=$((shown + 1)); [ "$shown" -ge "$N" ] && break
done < <(ls -1t "$DIR"/*.eml 2>/dev/null)
[ "$shown" = 0 ] && echo "no message yet in $DIR"
exit 0
