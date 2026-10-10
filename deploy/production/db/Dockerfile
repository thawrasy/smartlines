# Production database image (reviews of October 2026, packages 2 and 3): the PostGIS image of docker-compose.yml plus
#   * pgBackRest, which archives every WAL segment to a repository off this host (H-02);
#   * the start-up step that installs the TLS files and writes pg_hba.conf: TLS only on the network, the warehouse
#     login only from its address with a client certificate (H-05, H-10);
#   * the archive check the preflight reads through COPY ... FROM PROGRAM (backend/app/tools/preflight.py);
#   * no logical decoding plugin but pgoutput: test_decoding is removed, so a replication login cannot decode every
#     table into plain text (H-10);
#   * for the layout with two database hosts (H-01, deploy/production/ha): Patroni, from patroni.lock with the hashes
#     of every file; HAProxy, which the application host runs from this same image in front of the two hosts; and the
#     scripts both use.
FROM postgis/postgis:16-3.4-alpine@sha256:681931a625df344215e9b8998bf34daf146b6a395ceacee4439eb9c85869239f
COPY patroni.lock /tmp/patroni.lock
# Every package of patroni.lock is checked against its hashes; all are wheels but python-etcd and ydiff, which exist
# only as source and are pure Python (built with Alpine's setuptools, no compiler). --upgrade brings the libraries the
# pinned base image already has (libexpat) to the versions Alpine's current Python is built against.
RUN apk add --no-cache --upgrade libexpat pgbackrest python3 py3-pip py3-setuptools py3-wheel haproxy \
 && rm -f "$(pg_config --pkglibdir)/test_decoding.so" \
 && pip install --no-cache-dir --break-system-packages --ignore-installed --no-deps --no-build-isolation \
        --only-binary :all: --no-binary python-etcd,ydiff --require-hashes -r /tmp/patroni.lock \
 && patroni --version \
 && rm /tmp/patroni.lock \
 && mkdir -p /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest /etc/patroni \
 && chown -R postgres:postgres /var/spool/pgbackrest /var/log/pgbackrest
COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY patroni.yml /etc/patroni/patroni.yml
COPY entry.sh /usr/local/bin/masslak-db-entry
COPY archive-check.sh /usr/local/bin/masslak-archive-check
COPY patroni-bootstrap.sh /usr/local/bin/masslak-patroni-bootstrap
COPY proxy.sh /usr/local/bin/masslak-db-proxy
COPY patroni-config.py /usr/local/bin/masslak-patroni
COPY backup-if-primary.sh /usr/local/bin/masslak-backup-if-primary
RUN chmod 0644 /etc/pgbackrest/pgbackrest.conf /etc/patroni/patroni.yml \
 && cd /usr/local/bin && chmod 0755 masslak-db-entry masslak-archive-check masslak-patroni-bootstrap masslak-db-proxy \
                                    masslak-patroni masslak-backup-if-primary
ENTRYPOINT ["/usr/local/bin/masslak-db-entry"]
CMD ["docker-entrypoint.sh", "postgres"]
