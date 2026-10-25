# Restoring a server's configuration

Wave 7 (owner's notes 20-32). The data backup (`deploy/backup.sh`) holds the database and the files; this guide covers
the server's own configuration, saved weekly by `deploy/config-backup.sh` as an age-encrypted archive, on the server
in `/var/backups/masslak/config` and off the server in `MASSLAK_BACKUP_OFFSITE/config`.

Recovery targets stay as approved: RPO 60 seconds for the data, RTO 30 minutes for the service.

## What the archive holds

* `deploy/.env` and the per-service files in `deploy/env/`
* `deploy/production/secrets`, `deploy/production/tls`, `deploy/production/targets` and, with two database hosts, their bundles
* the host's hardening: `/etc/sysctl.d/99-masslak-hardening.conf`, the edge firewall script and unit, `/etc/ufw`,
  fail2ban's local jails, `/etc/docker/daemon.json`
* the platform's cron entries and rclone's configuration
* `MANIFEST` (host, date, release, system), `packages.txt`, `ufw-status.txt`

## Steps on a new server

1. Prepare the server as on the first day: `sudo ./deploy/server-setup.sh` (Docker, firewall, kernel settings, cron).
2. Fetch the latest archive and its checksum from the off-site copy and check it:
   `rclone copy offsite:masslak-backups/config/<archive> . && sha256sum -c <archive>.sha256`
3. Decrypt it on the server with the private key brought for this purpose (it is never kept on the server), then
   remove the key file:
   `age -d -i masslak-backup.key <archive> > config.tar.gz && shred -u masslak-backup.key`
4. List it before anything is written: `tar -tzf config.tar.gz | less`, and read `MANIFEST` for the release it belongs to.
5. Put the application's files back under the application directory (default `/opt/masslak`):
   `tar -xzf config.tar.gz -C / opt/masslak/deploy` (the archive keeps absolute paths without the leading slash)
6. Compare the host's files before replacing them: extract `etc/` into a scratch directory, `diff -r` it against `/etc`,
   and copy only what differs and is still wanted; then `sysctl --system`, `systemctl daemon-reload`,
   `systemctl restart masslak-edge-firewall fail2ban docker`.
7. Install the same release as in `MANIFEST` (`deploy/install.sh`), restore the data (`deploy/restore.sh`,
   RUNBOOKS.md), and run `deploy/production/preflight.sh`: it names anything still missing.
8. Delete `config.tar.gz` and the scratch directory; run `deploy/config-backup.sh` once so the new server has its
   own first archive.

## Rehearsal

Rehearse once a quarter on a scratch server together with the restore drill, and record the time each step took in
the rehearsal schedule of RUNBOOKS.md.
