# Staging database: the production image plus pgBackRest, so WAL archiving, backups and restores run exactly as in
# production (deploy/pitr), against a repository volume instead of the production bucket.
FROM postgis/postgis:16-3.4-alpine
RUN apk add --no-cache pgbackrest \
 && mkdir -p /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest \
 && chown -R postgres:postgres /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest
COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY 20-pgbackrest.sh /docker-entrypoint-initdb.d/
RUN chmod 0644 /etc/pgbackrest/pgbackrest.conf
