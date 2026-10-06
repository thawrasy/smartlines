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
echo "server ready: put the application in /opt/masslak and follow deploy/README.md"
