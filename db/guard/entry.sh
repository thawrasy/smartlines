#!/bin/sh
# Starts the database server with the settings guard (db/guard/masslak_guard.c) when this image has it: masslak_guard
# is added to the shared_preload_libraries given on the command line, or given alone when none is. The image decides,
# not the compose file, so an older image without the module still starts under a newer compose file (a rollback of
# images keeps the compose files of the newer release). The API's readiness check reports whether the guard is loaded,
# and a production server is not ready without it.
#   masslak-guard-entry <command> [args...]    e.g. masslak-guard-entry docker-entrypoint.sh postgres -c ...
set -eu
if [ -f "$(pg_config --pkglibdir)/masslak_guard.so" ]; then
  found=false n=$#
  for a in "$@"; do
    case "$a" in
      shared_preload_libraries=*)
        found=true
        case ",${a#*=}," in *,masslak_guard,*) ;; ,,) a="shared_preload_libraries=masslak_guard" ;; *) a="$a,masslak_guard" ;; esac ;;
    esac
    set -- "$@" "$a"
  done
  shift "$n"
  [ "$found" = true ] || set -- "$@" -c shared_preload_libraries=masslak_guard
fi
exec "$@"
