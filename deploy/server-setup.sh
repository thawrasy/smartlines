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

# Nightly backup at 02:15 server time, if the application lives in /opt/masslak
if [ -x /opt/masslak/deploy/backup.sh ]; then
  echo "15 2 * * * root /opt/masslak/deploy/backup.sh >> /var/log/masslak-backup.log 2>&1" > /etc/cron.d/masslak-backup
fi
echo "server ready: clone the repository to /opt/masslak and follow deploy/README.md"
