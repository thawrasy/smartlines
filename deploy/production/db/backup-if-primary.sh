#!/bin/sh
# A pgBackRest backup on a database host of the layout with two (reviews of October 2026, H-01), run by the host's
# cron (deploy/production/ha/install-db-host.sh writes /etc/cron.d/masslak-pgbackrest) on both hosts: only the one
# that is the primary now backs up, so the schedule follows a failover without anyone moving it.
#   masslak-backup-if-primary full|diff
set -eu
type="${1:?full or diff}"
primary="$(psql -h /var/run/postgresql -U postgres -d postgres -qAtX -c "SELECT NOT pg_is_in_recovery()")"
if [ "$primary" != t ]; then
  echo "masslak-backup-if-primary: this host is a standby now; the primary takes the $type backup"
  exit 0
fi
exec pgbackrest --stanza=masslak --type="$type" backup
