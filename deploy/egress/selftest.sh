#!/usr/bin/env bash
# Probes the egress proxy (audit T3-02): every forbidden destination must answer 403, an allowlisted name must not.
#   deploy/egress/selftest.sh [proxy host:port] [allowlisted domain]
# Run from a container on the application network, e.g.: docker compose exec worker /app/deploy/egress/selftest.sh egress:3128
set -uo pipefail
PROXY="${1:-127.0.0.1:3128}"; ALLOWED="${2:-}"
fail=0
probe() {   # method target expected
  local code
  code=$(python3 - "$PROXY" "$1" "$2" <<'PY'
import socket, sys
host, port = sys.argv[1].rsplit(":", 1)
s = socket.create_connection((host, int(port)), timeout=15)
s.sendall(f"{sys.argv[2]} {sys.argv[3]} HTTP/1.1\r\nHost: probe\r\n\r\n".encode())
print((s.recv(200).split(b"\r\n", 1)[0].split() + [b"", b"000"])[1].decode())
PY
)
  if [ "$code" = "$3" ] || { [ "$3" = "not403" ] && [ "$code" != "403" ]; }; then echo "ok    $1 $2 -> $code"
  else echo "FAIL  $1 $2 -> $code (expected $3)"; fail=1; fi
}
probe CONNECT 169.254.169.254:443 403      # cloud metadata
probe CONNECT 10.0.0.5:443 403             # private network
probe CONNECT 127.0.0.1:443 403            # loopback
probe CONNECT localhost:443 403            # a name that resolves to loopback
probe CONNECT "[::1]:443" 403              # IPv6 loopback
probe CONNECT "[::ffff:127.0.0.1]:443" 403 # IPv4-mapped IPv6
probe CONNECT not-allowlisted.example:443 403
probe GET http://example.com/ 403          # plain HTTP
[ -n "$ALLOWED" ] && probe CONNECT "$ALLOWED:22" 403   # an allowlisted name, wrong port
[ -n "$ALLOWED" ] && probe CONNECT "$ALLOWED:443" not403
[ $fail = 0 ] && echo "egress proxy: all probes passed" || { echo "egress proxy: FAILED"; exit 1; }
