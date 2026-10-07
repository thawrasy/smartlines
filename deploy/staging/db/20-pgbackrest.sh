#!/bin/sh
# Primary only: create the pgBackRest stanza once the cluster exists (archive-push retries until it does)
set -eu
pgbackrest --stanza=masslak --pg1-path="$PGDATA" stanza-create
