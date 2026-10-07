# Staging database: the production image plus pgBackRest, so WAL archiving, backups and restores run exactly as in
# production (deploy/pitr), against a repository volume instead of the production bucket.
FROM postgis/postgis:16-3.4-alpine
RUN apk add --no-cache pgbackrest \
 && mkdir -p /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest \
 && chown -R postgres:postgres /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest
COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY 10-replication.sh 20-pgbackrest.sh /docker-entrypoint-initdb.d/
COPY standby.sh /usr/local/bin/masslak-standby
RUN chmod 0644 /etc/pgbackrest/pgbackrest.conf && chmod 0755 /usr/local/bin/masslak-standby
