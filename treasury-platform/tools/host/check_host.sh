#!/usr/bin/env bash
# The host check (DOC-S16 section 8), run by a systemd timer every five minutes. It compares what listens, which
# containers run and the authorized_keys with the last accepted state, and checks disk, memory and the services. An
# alert goes to the journal (tag bankfas-alert, forwarded by the log shipper) and, if ALERT_MAIL is set, by mail.
# `check_host.sh accept` records the current state as accepted after a reviewed change.
set -uo pipefail
state=/var/lib/bankfas-check; mkdir -p "$state"; chmod 700 "$state"
ports() { ss -tulnH | awk '{print $1, $5}' | sort -u; }
containers() { docker ps --format '{{.Image}} {{.Names}}' 2>/dev/null | sort; }
keys() { sha256sum /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null | sort; }
if [ "${1:-}" = accept ]; then ports > "$state/ports"; containers > "$state/containers"; keys > "$state/keys"; echo accepted; exit 0; fi

alerts=()
for k in ports containers keys; do
  [ -f "$state/$k" ] || { "$k" > "$state/$k"; continue; }
  d="$(diff <(cat "$state/$k") <("$k"))" || alerts+=("$k changed: $(echo "$d" | grep '^[<>]' | head -5 | tr '\n' ';')")
done
disk="$(df --output=pcent / /var | tail -n +2 | tr -dc '0-9\n' | sort -n | tail -1)"
[ "${disk:-0}" -ge "${DISK_ALERT:-85}" ] && alerts+=("disk at ${disk}%")
mem="$(free | awk '/Mem:/ {printf "%d", ($3/$2)*100}')"
[ "${mem:-0}" -ge "${MEM_ALERT:-90}" ] && alerts+=("memory at ${mem}%")
for svc in caddy docker fail2ban auditd ufw; do systemctl is-active --quiet "$svc" || alerts+=("service $svc is not active"); done
bans="$(fail2ban-client status bankfas-caddy 2>/dev/null | awk -F: '/Currently banned/ {gsub(/ /,"",$2); print $2}')"
[ "${bans:-0}" -ge "${BAN_ALERT:-20}" ] && alerts+=("$bans addresses banned from the Caddy log: possible attack, see DOC-S16 section 10")

[ "${#alerts[@]}" -eq 0 ] && exit 0
for a in "${alerts[@]}"; do logger -p auth.warning -t bankfas-alert "$a"; done
if [ -n "${ALERT_MAIL:-}" ] && command -v mail >/dev/null; then
  printf '%s\n' "${alerts[@]}" | mail -s "BankFas host $(hostname -s): ${#alerts[@]} alert(s)" "$ALERT_MAIL"
fi
exit 1
