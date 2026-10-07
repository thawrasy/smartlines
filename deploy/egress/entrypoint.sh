#!/bin/sh
# The worker writes the partner endpoint domains into the shared lists volume; Squid rereads them every minute.
set -e
touch /etc/squid/lists/generated.txt
chmod 0777 /etc/squid/lists
squid -k parse -f /etc/squid/squid.conf
squid -N -f /etc/squid/squid.conf &
pid=$!
trap 'kill $pid; wait $pid; exit 0' TERM INT
while kill -0 $pid 2>/dev/null; do
  sleep 60
  squid -k reconfigure -f /etc/squid/squid.conf || true
done
wait $pid
