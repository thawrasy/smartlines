# The production profile

A production server installs and updates only in the production profile (reviews of October 2026, package 2). The
profile is an overlay of the standard stack, `deploy/production/docker-compose.production.yml`. Each part is checked
before the server migrates, updates or starts. A server that lacks a part refuses to go on and names what is missing.
Nothing runs half set up.

| Finding | What the profile requires | Checked by |
|---|---|---|
| H-02 | WAL archived by pgBackRest to a repository off this host, proven before every migration | migration preflight; update; alert `WalArchiveStale` |
| H-03 | Every backup copied off the server before an update | update (refuses), alert `BackupOffsiteStale` |
| H-05 | TLS to the database, the read replica and PgBouncer; every client checks the certificate (`verify-full`) | `pg_hba.conf` accepts nothing else; migration preflight; API start |
| H-06 | Data keys opened by the key service (Vault); each container receives only its part of `deploy/.env` | host preflight; API and worker start |
| H-07 | Prometheus, Alertmanager, node_exporter, the PgBouncer exporter, Grafana and ClamAV run on the server; alerts reach the receivers | host preflight (receivers); `alert-drill.sh`; alerts `MetricsMissing`, `ScrapeTargetDown` |
| H-09 | No constraint left NOT VALID | `/api/ready` |
| H-10 | Warehouse login only from its address, over TLS with a client certificate; no decoding plugin but pgoutput | `pg_hba.conf`; migration preflight |
| M-07 | No drift override (`MASSLAK_SCHEMA_DRIFT=warn`) | `db/upgrade.sh` |
| Addition 2 | Every metric an alert rests on is watched for absence | alert `MetricsMissing` |

## 1. What to prepare before installing

* **The key service.** Vault, or OpenBao, with the Transit engine and a key named `masslak-field`
  (`vault secrets enable transit`, `vault write -f transit/keys/masslak-field`). Give the server a token limited to that
  key:

  ```
  path "transit/encrypt/masslak-field" { capabilities = ["update"] }
  path "transit/decrypt/masslak-field" { capabilities = ["update"] }
  ```

  The server reaches Vault through its egress proxy. The proxy lets through exactly the host and port of
  `MASSLAK_VAULT_ADDR`, so Vault may sit at an internal address.

  When Vault's certificate is not from a public authority, copy that authority's certificate to
  `deploy/production/trust/vault-ca.crt` and set `MASSLAK_VAULT_CA_FILE=/etc/masslak/trust/vault-ca.crt`.
* **A repository for WAL and base backups off this host.** Object storage (S3, GCS, Azure), sftp, or a pgBackRest
  repository host. Set it with pgBackRest's own variables (`PGBACKREST_REPO1_*` in `deploy/.env.example`), with a
  cipher pass. The repository is encrypted.
* **The off-site copy of the nightly backups.** An rclone destination in `MASSLAK_BACKUP_OFFSITE`, and an age public
  key in `MASSLAK_BACKUP_AGE_RECIPIENT`, whose private key is kept off the server.
* **The alert receivers.** Three webhook addresses: the on-call channel (page), the team queue (ticket), and a dead
  man's switch that pages when the minute heartbeat stops (deadman).

## 2. Installing

```
sudo ./deploy/init-env.sh --domain masslak.com --email ops@masslak.com
sudo nano deploy/.env        # the key service, the pgBackRest repository, MASSLAK_BACKUP_OFFSITE, the age recipient
sudo ./deploy/production/init.sh
echo 'https://...' | sudo tee deploy/production/secrets/page_webhook_url     # likewise ticket_ and deadman_webhook_url
sudo ./deploy/install.sh --domain masslak.com --email ops@masslak.com --admin-email admin@masslak.com
```

`deploy/production/init.sh` prepares the server's side of the profile; running it again replaces nothing that
exists. It creates:

* an internal certificate authority;
* the database's certificate, for the names `db`, `db-replica`, `pgbouncer` and any in `MASSLAK_DB_TLS_NAMES`;
* the warehouse login's client certificate;
* the monitoring secrets;
* `COMPOSE_FILE` in `deploy/.env`, so every `docker compose --env-file deploy/.env ...` on the server uses the
  profile.

**Move `deploy/production/tls/ca.key` to offline storage** once the certificates exist. It is needed again only to
renew them.

`install.sh` then works in this order:

1. The host preflight (`deploy/production/preflight.sh`) checks `deploy/.env` and `deploy/production`.
2. `deploy/env-split.sh` writes one environment file per container.
3. The images are built and the stack starts. The migration first runs the database preflight
   (`python -m app.tools.preflight`) on the database itself:
   * TLS is on and is the only way in;
   * `pg_hba.conf` asks for scram and, for the warehouse, a certificate;
   * WAL archiving works now (pgBackRest's own check, against the repository);
   * the repository is off this host;
   * no decoding plugin but pgoutput is installed.
4. The migration then wraps every data key with the key service (`python -m app.tools.keys bootstrap`). The API and
   the worker never hold a clear key in their environment.

A production `deploy/.env` has no `MASSLAK_FIELD_KEYS` or `MASSLAK_BIDX_KEY`: the key service makes the keys at the
first migration and only their wrapped form is stored (`sec.key_registry`).

## 3. What each container receives

`deploy/env-split.sh` writes `deploy/env/<service>.env` from `deploy/.env` (mode 600). Run it again after editing
`deploy/.env`; `install.sh`, `update.sh` and `restore.sh` run it themselves.

| Container | Receives | Never receives |
|---|---|---|
| app, worker | Settings, the signing keys, the key service's address and token | The owner's password; replication, warehouse and telemetry-owner passwords; backup and pgBackRest settings; on a production server, any data key |
| migrate | Everything but backup and pgBackRest settings | — |
| db | The owner's login, pgBackRest's repository, the warehouse's address | — |

The API and the worker check this themselves at start (`app/profile.py`). They also refuse to start:

* outside the production profile;
* with a database connection that does not check the certificate;
* without the key service.

## 4. Updating

`deploy/update.sh` on a production server runs these steps in order:

1. The host preflight.
2. The build.
3. A restart of the database, its replica and PgBouncer, only if their image or settings changed.
4. The database preflight.
5. The backup. It must be copied off the server, or the update stops: nothing has been changed at that point.
6. The update itself.
7. The WAL archive check, which must pass.

`MASSLAK_SCHEMA_DRIFT=warn` is refused on a production server, whether the environment or the database declares it
production.

**Switching an existing production server to the profile.**

1. Fill in the settings of section 1.
2. Run `./deploy/update.sh`. The first run restarts the database with TLS and archiving.
3. The migration wraps the data keys that `deploy/.env` still gives (`MASSLAK_FIELD_KEYS`, `MASSLAK_BIDX_KEY`), so
   what they sealed stays readable. Once the API is ready, remove those two lines from `deploy/.env` and keep them
   only in the secret store.
4. If `/api/ready` reports `"constraints": false`, see RUNBOOKS.md, section 31.

## 5. The warehouse in production

The warehouse runs on its own server. On the primary, set `MASSLAK_WAREHOUSE_ADDRESS` to its address (for example
`10.0.4.12/32`). Copy to the warehouse server:

* `deploy/production/tls/ca.crt`;
* `masslak_cdc.crt` and `masslak_cdc.key`, readable by its PostgreSQL server only (mode 600).

It subscribes with:

```
MASSLAK_DW_SOURCE="host=<the primary's name> dbname=masslak user=masslak_cdc password=... sslmode=verify-full
                   sslrootcert=/etc/masslak/ca.crt sslcert=/etc/masslak/masslak_cdc.crt sslkey=/etc/masslak/masslak_cdc.key"
```

The primary's name must be one of the certificate's names (`MASSLAK_DB_TLS_NAMES`). The database refuses the
warehouse login from anywhere else, and without the certificate. Only pgoutput can decode WAL: the production
database image has no other decoding plugin. To rotate the password, see RUNBOOKS.md, section 31.

## 6. Monitoring

The profile runs the monitoring on the server itself:

* Prometheus, with the alert rules of `deploy/monitoring/alerts.yml`;
* Alertmanager;
* node_exporter, for disks, memory and the textfile collector;
* the PgBouncer exporter;
* Grafana, at `127.0.0.1:3000`, reached through an SSH tunnel;
* ClamAV, for the file scanner.

Set `MASSLAK_SITE_B_METRICS` (host:port of the second site's node_exporter) to scrape the second site's watchdog.

Two rules guard the monitoring itself:

* `MetricsMissing` fires when a metric an alert rests on stops arriving, and names it.
* `ScrapeTargetDown` fires when a target stops answering.

`./deploy/monitoring/alert-drill.sh` proves the path to the people on call. It sends a synthetic page, checks that
Alertmanager delivered it without a failure, and resolves it. Run it after installing, after changing a receiver, and
monthly. The person on call confirms receipt; the drill is recorded as launch gate evidence.

## 7. What the profile does not do yet

These are in package 3:

* hosts of their own for the database and its standby (H-01);
* object versions recorded with backups when files are in object storage (H-04);
* images built once in CI and signed (H-08);
* TLS to the telemetry database (overlay `deploy/telemetry`).

The profile runs on one host. On that host, TLS and the address rules protect against a container or a password
leaking, not against a lost host. That is what the second site and package 3 cover.
