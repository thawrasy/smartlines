#!/usr/bin/env bash
# Installs the station display hub (owner's note N46, hub/, docs/design/STATION_DISPLAYS_LAN.md) on the station's own
# box (a mini PC or a virtual machine, Ubuntu or Debian with Docker), from the extracted release or a checkout:
#
#   sudo ./deploy/hub-install.sh --platform https://masslak.example --code ABCD2345 [--listen 10.20.0.1] [--port 8080]
#
# --code is the one-time code the station's administration made in the station portal (Screens > Screens on the
# station's own network). --listen is the hub's address on the screens' network (VLAN): the hub serves the players
# there only. The hub reaches the platform outbound over HTTPS only; nothing reaches it from the internet.
# Run it again without --code to update the hub; its key and state stay in /var/lib/masslak-hub.
set -euo pipefail
cd "$(dirname "$0")/.."
platform="" code="" listen="0.0.0.0" port="8080"
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="$2"; shift 2 ;;
    --code) code="$2"; shift 2 ;;
    --listen) listen="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker is needed: https://docs.docker.com/engine/install/" >&2; exit 1; }
state=/var/lib/masslak-hub
image="masslak-hub:$(cat VERSION 2>/dev/null || echo local)"

docker build -q -t "$image" hub >/dev/null
install -d -m 700 -o 10001 -g 10001 "$state"
run=(docker run --rm --network host --read-only --cap-drop ALL --security-opt no-new-privileges
     -v "$state:/var/lib/masslak-hub" "$image")

if [ -n "$code" ]; then
  [ -n "$platform" ] || { echo "--platform is needed with --code" >&2; exit 2; }
  "${run[@]}" pair --platform "$platform" --code "$code"
fi
[ -f "$state/key" ] || { echo "the hub is not paired: give --platform and --code" >&2; exit 1; }

docker rm -f masslak-hub >/dev/null 2>&1 || true
# host networking: the hub must read the players' hardware addresses from the host's ARP table (/proc/net/arp)
docker run -d --name masslak-hub --restart unless-stopped --network host --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges --log-opt max-size=20m --log-opt max-file=5 \
  -v "$state:/var/lib/masslak-hub" -e MASSLAK_HUB_HOST="$listen" -e MASSLAK_HUB_PORT="$port" \
  "$image" serve >/dev/null
sleep 3
curl -fsS "http://127.0.0.1:$port/healthz" 2>/dev/null || curl -fsS "http://$listen:$port/healthz" || true
echo
echo "The hub serves the screens at http://$listen:$port/screen/<screen code>"
echo "Each player opens its screen's address once; approve it in the station portal under Screens."
