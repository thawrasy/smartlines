#!/usr/bin/env bash
# Prepares a fresh Ubuntu 22.04 / 24.04 server for Masslak. Run once as root:
#   curl -fsSL <raw URL of this file> | bash      or      sudo ./deploy/server-setup.sh
# Installs Docker Engine with the Compose plugin, opens only SSH, HTTP and HTTPS, enables automatic security
# updates and fail2ban for SSH, and schedules the nightly backup.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
. /etc/os-release
[ "$ID" = ubuntu ] || echo "warning: tested on Ubuntu only (found $ID)"
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get install -yq ca-certificates curl gnupg ufw fail2ban unattended-upgrades age git

# Docker Engine from Docker's own repository (the distribution package lags behind)
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
# Rotate container logs so they never fill the disk
cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }
JSON
systemctl enable --now docker
systemctl restart docker

# Firewall: SSH, HTTP (certificate challenge and redirect), HTTPS over TCP and QUIC
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable
# Docker publishes ports through iptables, bypassing ufw: the stack publishes only Caddy's 80 and 443.

# Kernel network hardening (owner's request, October 2026): make the host itself hard to exhaust with
# background floods (ping/ICMP, half-open SYN connections, spoofed source addresses) before any packet
# reaches Caddy or the API. These are defence in depth under the application shield (migration 1142).
cat > /etc/sysctl.d/99-masslak-hardening.conf <<'SYSCTL'
# Ignore ICMP echo broadcasts (smurf amplification) and rate-limit how fast the host answers pings at all,
# so "ping -f" style floods cannot keep a core busy answering. The site does not rely on being pingable.
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ratemask = 88089
# SYN-flood protection: cookies let the host keep accepting real connections while a flood of half-open
# ones is in flight, with a deeper backlog and fewer retransmits so a stuck handshake is dropped sooner.
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.core.somaxconn = 4096
# Reverse-path filtering drops spoofed source addresses; logging martians keeps a trace of attempts.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
# Do not accept ICMP redirects (route poisoning) on a server that does not route for anyone.
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.default.accept_source_route = 0
# Wave 7 (owner's notes 20-32): the host itself. RFC 1337 drops stray resets of closed connections; kernel pointers and
# the kernel log are hidden from users who are not root; a process may trace only its own children; unprivileged
# processes cannot load BPF programs and the BPF compiler is hardened; links in shared directories cannot be used to
# trick a privileged process; programs that change user never leave a core file behind.
net.ipv4.tcp_rfc1337 = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
SYSCTL
sysctl --quiet --system || true

# Edge connection rate limit at the kernel (owner's request): throttle new TCP connections per source
# address to the published web ports before they reach Caddy, so a single host cannot open connections
# faster than any real browser would. Docker's own rules sit in the FORWARD chain, so the limit goes in
# DOCKER-USER, which Docker evaluates first and never flushes. The ceiling is deliberately generous
# (200 new connections/second per address, short burst) — real traffic, even behind a shared NAT, stays
# well under it; a flood does not. Per-request abuse is handled above this by the application shield.
install -m 0755 /dev/stdin /usr/local/sbin/masslak-edge-firewall.sh <<'EDGE'
#!/usr/bin/env bash
# Applied by masslak-edge-firewall.service after Docker has created DOCKER-USER. Idempotent: it removes its
# own rules (marked with the comment) before adding them again.
set -euo pipefail
command -v iptables >/dev/null || exit 0
iptables -w -L DOCKER-USER >/dev/null 2>&1 || exit 0
# drop our previous rules so a restart does not stack them
while iptables -w -L DOCKER-USER --line-numbers 2>/dev/null | awk '/masslak-edge/ {print $1}' | tail -1 | grep -q .; do
  n=$(iptables -w -L DOCKER-USER --line-numbers | awk '/masslak-edge/ {print $1}' | tail -1)
  iptables -w -D DOCKER-USER "$n"
done
for port in 80 443; do
  iptables -w -I DOCKER-USER -p tcp --dport "$port" --syn \
    -m hashlimit --hashlimit-name "msk$port" --hashlimit-mode srcip \
    --hashlimit-above 200/sec --hashlimit-burst 300 \
    -m comment --comment "masslak-edge" -j DROP
done
EDGE
cat > /etc/systemd/system/masslak-edge-firewall.service <<'UNIT'
[Unit]
Description=Masslak edge connection rate limit (DOCKER-USER)
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/masslak-edge-firewall.sh
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now masslak-edge-firewall.service || echo "warning: edge rate-limit rules will apply on next boot"

systemctl enable --now fail2ban unattended-upgrades

# Small servers: the first image build (web interface and Python packages) needs more than 2 GB of memory
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$mem_mb" -lt 3800 ] && [ "$(swapon --noheadings | wc -l)" = 0 ] && [ ! -e /swapfile ]; then
  echo "adding a 2 GB swap file (server has ${mem_mb} MB of memory)"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# Nightly backup at 02:15 server time, for the installation this script belongs to (the default is /opt/masslak)
app_dir="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || true)"
[ -x "$app_dir/deploy/backup.sh" ] || app_dir=/opt/masslak
if [ -x "$app_dir/deploy/backup.sh" ]; then
  echo "15 2 * * * root $app_dir/deploy/backup.sh >> /var/log/masslak-backup.log 2>&1" > /etc/cron.d/masslak-backup
  echo "nightly backup scheduled for $app_dir"
fi
# Hourly signed export of the audit logs (deploy/audit-archive.sh; settings and the sync to storage with object lock in
# deploy/.env, docs/operations/RUNBOOKS.md section 7)
if [ -x "$app_dir/deploy/audit-archive.sh" ]; then
  echo "5 * * * * root $app_dir/deploy/audit-archive.sh >> /var/log/masslak-audit-archive.log 2>&1" > /etc/cron.d/masslak-audit-archive
  echo "hourly audit archive scheduled for $app_dir"
fi
# Weekly encrypted copy of the server's own configuration (deploy/config-backup.sh; restore guide
# docs/operations/SERVER_CONFIG_RESTORE.md)
if [ -x "$app_dir/deploy/config-backup.sh" ]; then
  echo "20 3 * * 0 root $app_dir/deploy/config-backup.sh >> /var/log/masslak-config-backup.log 2>&1" > /etc/cron.d/masslak-config-backup
  echo "weekly configuration backup scheduled for $app_dir"
fi
# Shared memory is never a place to run programs from
grep -q '^tmpfs /dev/shm' /etc/fstab || echo "tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0" >> /etc/fstab
mount -o remount,nodev,nosuid,noexec /dev/shm 2>/dev/null || true
# SSH itself (keys only, no root password, a changed port) is set with the owner present (wave 9): this script leaves
# the SSH daemon's settings as they are
echo "server ready: put the application in /opt/masslak and follow deploy/README.md"
