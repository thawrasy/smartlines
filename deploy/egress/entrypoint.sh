#!/bin/sh
# The worker writes the partner endpoint domains into the shared lists volume; Squid rereads them within a minute of a
# change. Only a change reconfigures it: a reconfigure closes and reopens the listening port, and a call made in that
# moment is refused.
set -e
touch /etc/squid/lists/generated.txt
chmod 0777 /etc/squid/lists
# The key service: CONNECT to MASSLAK_VAULT_ADDR's host and port, and nothing else, may reach an internal address
# (reviews of October 2026, H-06). A host given as an address is matched as one.
: > /etc/squid/keyservice.conf
if [ -n "${MASSLAK_VAULT_ADDR:-}" ]; then
  hostport="${MASSLAK_VAULT_ADDR#*://}"; hostport="${hostport%%/*}"
  case "$hostport" in
    \[*\]:*) host="${hostport%%]:*}"; host="${host#[}"; port="${hostport##*]:}" ;;
    \[*\]) host="${hostport#[}"; host="${host%]}"; port=443 ;;
    *:*) host="${hostport%:*}"; port="${hostport##*:}" ;;
    *) host="$hostport"; port=443 ;;
  esac
  if printf '%s' "$host" | grep -Eq '^[0-9.]+$|:'; then acl="dst $host"; else acl="dstdomain $host"; fi
  printf 'acl keyservice %s\nacl keyservice_port port %s\nhttp_access allow CONNECT keyservice keyservice_port\n' "$acl" "$port" \
    > /etc/squid/keyservice.conf
  echo "egress: the key service at $host:$port may be reached"
fi
squid -k parse -f /etc/squid/squid.conf
squid -N -f /etc/squid/squid.conf &
pid=$!
trap 'kill $pid; wait $pid; exit 0' TERM INT
lists() { cat /etc/squid/lists/* 2>/dev/null | cksum; }
seen=$(lists)
while kill -0 $pid 2>/dev/null; do
  sleep 60
  now=$(lists)
  if [ "$now" != "$seen" ]; then
    squid -k reconfigure -f /etc/squid/squid.conf && seen=$now || true
  fi
done
wait $pid
