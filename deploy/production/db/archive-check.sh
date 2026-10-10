#!/bin/sh
# What the production preflight needs to know from inside the database container (backend/app/tools/preflight.py),
# run by the owner through COPY ... FROM PROGRAM: where the pgBackRest repository is, whether pgBackRest's own check
# archives a WAL segment to it now (it creates the stanza first if this is a new repository), and which logical
# decoding plugins other than pgoutput are installed. Each line is key=<base64 value>, so COPY reads any text as is.
out() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"; }
conf=/etc/pgbackrest/pgbackrest.conf
repo_type="${PGBACKREST_REPO1_TYPE:-$(sed -n 's/^repo1-type=//p' "$conf" | tail -1)}"
repo_host="${PGBACKREST_REPO1_HOST:-$(sed -n 's/^repo1-host=//p' "$conf" | tail -1)}"
out repo_type "${repo_type:-posix}"
out repo_host "$repo_host"
created="$(pgbackrest --stanza=masslak stanza-create 2>&1)"
if checked="$(pgbackrest --stanza=masslak check 2>&1)"; then out check_ok 1; else out check_ok 0; fi
out check_output "$(printf '%s\n%s' "$created" "$checked" | tail -n 20)"
plugins=""
for p in test_decoding wal2json decoderbufs decoder_raw; do
  [ -e "$(pg_config --pkglibdir)/$p.so" ] && plugins="$plugins $p"
done
out plugins "${plugins# }"
exit 0
