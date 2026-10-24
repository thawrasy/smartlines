# Staging database: the production image plus pgBackRest, so WAL archiving, backups and restores run exactly as in
# production (deploy/pitr), against a repository volume instead of the production bucket; and the settings guard
# (db/guard, build context guard-src), loaded with the server as in production.
FROM postgis/postgis:16-3.4-alpine@sha256:681931a625df344215e9b8998bf34daf146b6a395ceacee4439eb9c85869239f AS guard
RUN apk add --no-cache gcc make musl-dev
COPY --from=guard-src masslak_guard.c Makefile /src/
RUN make -C /src with_llvm=no

FROM postgis/postgis:16-3.4-alpine@sha256:681931a625df344215e9b8998bf34daf146b6a395ceacee4439eb9c85869239f
COPY --from=guard /src/masslak_guard.so /tmp/masslak_guard.so
COPY --from=guard-src entry.sh /usr/local/bin/masslak-guard-entry
RUN install -m 0755 /tmp/masslak_guard.so "$(pg_config --pkglibdir)/masslak_guard.so" && rm /tmp/masslak_guard.so \
 && chmod 0755 /usr/local/bin/masslak-guard-entry
RUN apk add --no-cache pgbackrest \
 && mkdir -p /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest \
 && chown -R postgres:postgres /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest
COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY 20-pgbackrest.sh /docker-entrypoint-initdb.d/
RUN chmod 0644 /etc/pgbackrest/pgbackrest.conf
ENTRYPOINT ["/usr/local/bin/masslak-guard-entry", "docker-entrypoint.sh"]
CMD ["postgres"]
