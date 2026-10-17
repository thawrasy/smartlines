# PostgreSQL with PostGIS and the settings guard (masslak_guard.c): the database of docker-compose.yml, its read replica,
# and the database the CI jobs test against. The production image (deploy/production/db) and the staging image
# (deploy/staging/db) build the same module the same way, from this directory (build context guard-src).
FROM postgis/postgis:16-3.4-alpine@sha256:681931a625df344215e9b8998bf34daf146b6a395ceacee4439eb9c85869239f AS build
RUN apk add --no-cache gcc make musl-dev
COPY masslak_guard.c Makefile /src/
# the server's JIT bitcode needs clang, which a module that only defines settings does not need
RUN make -C /src with_llvm=no

FROM postgis/postgis:16-3.4-alpine@sha256:681931a625df344215e9b8998bf34daf146b6a395ceacee4439eb9c85869239f
COPY --from=build /src/masslak_guard.so /tmp/masslak_guard.so
COPY entry.sh /usr/local/bin/masslak-guard-entry
RUN install -m 0755 /tmp/masslak_guard.so "$(pg_config --pkglibdir)/masslak_guard.so" \
 && rm /tmp/masslak_guard.so \
 && chmod 0755 /usr/local/bin/masslak-guard-entry
ENTRYPOINT ["/usr/local/bin/masslak-guard-entry", "docker-entrypoint.sh"]
CMD ["postgres"]
