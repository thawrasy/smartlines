#!/usr/bin/env bash
# The database's TLS certificate for the private trial by address (site.conf ACCESS=ip, docs/62), where there is no
# domain to prove for a public certificate. It makes a certificate authority of this trial (once; kept in
# /opt/bankfas/trial-ca, root-only), signs a certificate for the database's name DB_HOST with it, gives the
# certificate and key to SQL Server (/var/opt/mssql/certs, mssql's, the key mode 600), and adds the authority to this
# host's trusted authorities, which the two containers read (compose.yml mounts /etc/ssl/certs/ca-certificates.crt).
# The connections stay encrypted and checked: nothing trusts any certificate (no TrustServerCertificate, no -C).
# Run as root from treasury-platform/ after SQL Server is installed. Safe to run again: the authority is kept, the
# certificate is signed again when it has fewer than 30 days left, or with --renew.
#
# Usage: sudo tools/host/trial_db_cert.sh [--renew]
# BANKFAS_ROOT (default /) puts every path under another folder, for a dry run; BANKFAS_NO_MSSQL=1 skips mssql-conf.
set -euo pipefail
R="${BANKFAS_ROOT:-}"; R="${R%/}"
SITE="${BANKFAS_SITE:-$R/opt/bankfas/site.conf}"
RENEW=0; [ "${1:-}" = --renew ] && RENEW=1
fail() { echo "trial_db_cert: $*" >&2; exit 1; }
step() { echo "== $*"; }
[ "$(id -u)" = 0 ] || fail "run it as root"
[ -f "$SITE" ] || fail "no $SITE (tools/host/site.conf.example)"
command -v openssl >/dev/null || fail "openssl is not installed (sudo apt-get install -y openssl)"
DB_HOST="$(grep -E '^DB_HOST=' "$SITE" | head -1 | cut -d= -f2-)"
ACCESS="$(grep -E '^ACCESS=' "$SITE" | head -1 | cut -d= -f2-)"
[ "${ACCESS:-domain}" = ip ] || fail "ACCESS is not ip in $SITE: with a domain the database has a public certificate (docs/54 B-08)"
[[ "$DB_HOST" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || fail "DB_HOST is not a host name"

CA="$R/opt/bankfas/trial-ca"
install -d -m 700 "$CA"
step "the trial's certificate authority"
if [ -f "$CA/ca.key" ] && [ -f "$CA/ca.crt" ]; then
    echo "   kept $CA/ca.crt"
else
    ( umask 077; openssl genrsa -out "$CA/ca.key" 3072 2>/dev/null )
    openssl req -x509 -new -key "$CA/ca.key" -sha256 -days 1825 -subj "/CN=BankFas trial authority $(hostname -s)" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$CA/ca.crt"
    echo "   created $CA/ca.crt (5 years)"
fi
echo "   fingerprint: $(openssl x509 -noout -fingerprint -sha256 -in "$CA/ca.crt" | cut -d= -f2)"

step "the certificate of $DB_HOST"
CERTS="$R/var/opt/mssql/certs"
install -d -m 755 "$CERTS"
if [ "$RENEW" = 0 ] && [ -f "$CERTS/db.pem" ] && openssl x509 -checkend 2592000 -noout -in "$CERTS/db.pem" >/dev/null 2>&1 \
    && openssl x509 -noout -ext subjectAltName -in "$CERTS/db.pem" 2>/dev/null | grep -q "DNS:$DB_HOST"; then
    echo "   kept: valid for 30 days or more"
else
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
    ( umask 077; openssl genrsa -out "$WORK/db.key" 2048 2>/dev/null )
    openssl req -new -key "$WORK/db.key" -subj "/CN=$DB_HOST" -out "$WORK/db.csr"
    printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$DB_HOST" > "$WORK/ext"
    openssl x509 -req -in "$WORK/db.csr" -CA "$CA/ca.crt" -CAkey "$CA/ca.key" -CAcreateserial -days 825 -sha256 -extfile "$WORK/ext" -out "$WORK/db.crt" 2>/dev/null
    cat "$WORK/db.crt" "$CA/ca.crt" > "$WORK/db.pem"
    owner=root; id mssql >/dev/null 2>&1 && owner=mssql
    install -o "$owner" -g "$owner" -m 0644 "$WORK/db.pem" "$CERTS/db.pem"
    install -o "$owner" -g "$owner" -m 0600 "$WORK/db.key" "$CERTS/db.key"
    echo "   signed for 825 days: $CERTS/db.pem and db.key ($owner's, the key mode 600)"
fi

step "this host and the containers trust the authority"
install -d -m 755 "$R/usr/local/share/ca-certificates"
install -m 644 "$CA/ca.crt" "$R/usr/local/share/ca-certificates/bankfas-trial-ca.crt"
if [ -z "$R" ]; then update-ca-certificates >/dev/null; echo "   in /etc/ssl/certs/ca-certificates.crt (restart the containers after a change)"
else echo "   (dry run: update-ca-certificates skipped)"; fi

step "SQL Server"
if [ "${BANKFAS_NO_MSSQL:-0}" = 1 ] || [ ! -x "$R/opt/mssql/bin/mssql-conf" ]; then
    echo "   skipped: set it yourself with mssql-conf network.tlscert /var/opt/mssql/certs/db.pem, network.tlskey /var/opt/mssql/certs/db.key"
else
    "$R/opt/mssql/bin/mssql-conf" set network.tlscert /var/opt/mssql/certs/db.pem >/dev/null
    "$R/opt/mssql/bin/mssql-conf" set network.tlskey /var/opt/mssql/certs/db.key >/dev/null
    "$R/opt/mssql/bin/mssql-conf" set network.forceencryption 1 >/dev/null
    systemctl restart mssql-server
    echo "   network.tlscert, network.tlskey and network.forceencryption set; mssql-server restarted"
fi
grep -qE "^127\.0\.0\.1[[:space:]]+${DB_HOST//./\\.}([[:space:]]|$)" "$R/etc/hosts" 2>/dev/null \
    || echo "   note: $DB_HOST is not yet 127.0.0.1 in /etc/hosts (provision_app_host.sh adds it with DB_ADDRESS)"
echo "done"
