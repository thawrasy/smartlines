# Production database image (reviews of October 2026, package 2): the PostGIS image of docker-compose.yml plus
#   * pgBackRest, which archives every WAL segment to a repository off this host (H-02);
#   * the start-up step that installs the TLS files and writes pg_hba.conf: TLS only on the network, the warehouse
#     login only from its address with a client certificate (H-05, H-10);
#   * the archive check the preflight reads through COPY ... FROM PROGRAM (backend/app/tools/preflight.py);
#   * no logical decoding plugin but pgoutput: test_decoding is removed, so a replication login cannot decode every
#     table into plain text (H-10).
FROM postgis/postgis:16-3.4-alpine@sha256:681931a625df344215e9b8998bf34daf146b6a395ceacee4439eb9c85869239f
RUN apk add --no-cache pgbackrest \
 && rm -f "$(pg_config --pkglibdir)/test_decoding.so" \
 && mkdir -p /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest \
 && chown -R postgres:postgres /var/spool/pgbackrest /var/log/pgbackrest
COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY entry.sh /usr/local/bin/masslak-db-entry
COPY archive-check.sh /usr/local/bin/masslak-archive-check
RUN chmod 0644 /etc/pgbackrest/pgbackrest.conf \
 && chmod 0755 /usr/local/bin/masslak-db-entry /usr/local/bin/masslak-archive-check
ENTRYPOINT ["/usr/local/bin/masslak-db-entry"]
CMD ["docker-entrypoint.sh", "postgres"]
