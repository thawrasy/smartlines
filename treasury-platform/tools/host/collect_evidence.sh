#!/usr/bin/env bash
# DOC-S15 section 9, steps 2, 5, 6 and 9 of the response (DOC-S16 section 9): on a suspicion, copy the logs with a
# timestamp and checksums, and record what runs, listens and may sign in. It reads only: it stops nothing, deletes
# nothing and restarts nothing (step 1). Run as root; the output goes to EVIDENCE_DIR (default /var/tmp), then off
# the host with the push account (DOC-S12 section 5.2) before anything is changed.
set -uo pipefail
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
host="$(hostname -s)"
out="${EVIDENCE_DIR:-/var/tmp}/evidence-$host-$stamp"
umask 077
mkdir -p "$out"/logs "$out"/state
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$out/collect.log"; }
run() { local name="$1"; shift; "$@" > "$out/state/$name.txt" 2>&1; log "state $name: exit $?"; }

log "evidence of $host by ${SUDO_USER:-$USER}"
# Step 2: the logs, copied as they are.
for p in /var/log/caddy /var/log/auth.log* /var/log/ufw.log* /var/log/fail2ban.log* /var/log/audit /var/log/syslog*; do
  [ -e "$p" ] && cp -a "$p" "$out/logs/" && log "copied $p"
done
journalctl --since "-14 days" -o export > "$out/logs/journal.export" 2>/dev/null; log "journal: exit $?"
for c in $(docker ps -aq 2>/dev/null); do docker logs --timestamps "$c" > "$out/logs/container-$c.log" 2>&1; done
# Step 5: processes, ports and containers.
run processes ps auxfww
run listening ss -tulpnH
run connections ss -tnpH state established
run containers docker ps -a --no-trunc --format '{{.ID}} {{.Image}} {{.CreatedAt}} {{.Status}} {{.Ports}} {{.Names}}'
run images docker images --digests --no-trunc
run container_changes bash -c 'for c in $(docker ps -q); do echo "== $c"; docker diff "$c"; done'
run cron bash -c 'ls -la /etc/cron* /var/spool/cron 2>/dev/null; systemctl list-timers --all'
run units systemctl list-units --type=service --all
# Step 6: users and keys.
run users getent passwd
run sudoers bash -c 'cat /etc/sudoers; cat /etc/sudoers.d/* 2>/dev/null'
run authorized_keys bash -c 'for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do [ -f "$f" ] && { echo "== $f"; stat -c "%y %U" "$f"; cat "$f"; }; done'
run last_logins last -Fwx -n 200
# Step 9: the compose files and the firewall as they are.
run compose bash -c 'ls -la /opt/bankfas; sha256sum /opt/bankfas/*.yml 2>/dev/null'
run firewall bash -c 'ufw status verbose; iptables-save'
run fail2ban bash -c 'fail2ban-client status; for j in sshd bankfas-caddy; do fail2ban-client status "$j"; done'

( cd "$out" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
tar -C "$(dirname "$out")" -czf "$out.tar.gz" "$(basename "$out")"
sha256sum "$out.tar.gz" | tee "$out.tar.gz.sha256"
log "done: $out.tar.gz; record its checksum in the incident (plat.SecurityIncident) before it leaves the host"
