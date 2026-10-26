#!/usr/bin/env bash
# Wave 9: SSH on the server, set with the owner present (docs/security/SSH_HARDENING.md).
#
# Each person who manages the server gets a named account that signs in with their own key; root no longer signs in,
# passwords no longer open a session, and SSH listens only where the owner chose. Nothing here asks for or stores a
# private key: each person makes their key on their own computer and hands over the public half (a .pub file).
#
#   sudo ./deploy/ssh-harden.sh --admin NAME:/path/to/NAME.pub [--admin ...] [--port 2222] [--allow 203.0.113.0/24,...]
#                               [--totp] [--banner-file /root/banner.txt] [--apply]
#   sudo ./deploy/ssh-harden.sh --close-port 22 --apply     # once every admin has signed in on the new port
#   sudo ./deploy/ssh-harden.sh --rollback --apply          # back to the settings found before the first run
#
# Without --apply it only prints what it would do. With --apply it keeps the session it runs in open, checks every key
# and the new settings (sshd -t) before reloading, opens the new port in the firewall before SSH moves to it, and keeps
# the old port open until --close-port. Keep this session open and sign in from a second window before closing it.
set -euo pipefail

CONF=/etc/ssh/sshd_config.d/10-masslak.conf
BACKUP_DIR=/root/ssh-harden-backup
BANNER=/etc/issue.net
admins=() port="" allow="" totp=false apply=false rollback=false close_port="" banner_file=""

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --admin) admins+=("${2:?--admin needs NAME:KEYFILE}"); shift 2 ;;
    --port) port="${2:?--port needs a number}"; shift 2 ;;
    --allow) allow="${2:?--allow needs addresses}"; shift 2 ;;
    --totp) totp=true; shift ;;
    --banner-file) banner_file="${2:?--banner-file needs a file}"; shift 2 ;;
    --close-port) close_port="${2:?--close-port needs a number}"; shift 2 ;;
    --rollback) rollback=true; shift ;;
    --apply) apply=true; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

say() { echo "  $*"; }
run() { if $apply; then "$@"; else say "would run: $*"; fi; }
die() { echo "stopped: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run it with sudo"
command -v sshd >/dev/null || die "the OpenSSH server is not installed"
$apply || echo "Dry run: nothing is changed. Add --apply to make the changes listed below."

if $rollback; then
  [ -d "$BACKUP_DIR" ] || die "no backup in $BACKUP_DIR: nothing to roll back"
  run rm -f "$CONF"
  if [ -f "$BACKUP_DIR/10-masslak.conf" ]; then run cp "$BACKUP_DIR/10-masslak.conf" "$CONF"; fi
  run sshd -t
  run systemctl reload ssh
  say "SSH settings are back to those found before the first run; accounts and keys were left in place"
  exit 0
fi

if [ -n "$close_port" ]; then
  [ "$close_port" != "${port:-}" ] || die "--close-port is the port SSH listens on"
  grep -q "^Port " "$CONF" 2>/dev/null || die "SSH has not moved to another port yet ($CONF has no Port line)"
  run ufw delete allow "$close_port/tcp"
  run ufw delete allow OpenSSH
  say "port $close_port is closed in the firewall; SSH keeps listening only on the port in $CONF"
  exit 0
fi

[ ${#admins[@]} -gt 0 ] || die "name at least one administrator: --admin NAME:/path/to/NAME.pub"
[ -z "$port" ] || [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] || die "--port must be 1024 to 65535"

# 1. Accounts and keys: each administrator signs in as themselves, with their own key, and uses sudo
users=()
for a in "${admins[@]}"; do
  name="${a%%:*}" key="${a#*:}"
  [[ "$name" =~ ^[a-z][a-z0-9_-]{1,31}$ ]] || die "'$name' is not an account name (lower-case letters, digits, - and _)"
  [ "$name" != root ] || die "root does not sign in; name a person's account"
  [ -f "$key" ] || die "no public key file $key for $name"
  grep -q "PRIVATE KEY" "$key" && die "$key is a PRIVATE key: hand over only the .pub file and keep the private one"
  ssh-keygen -lf "$key" >/dev/null 2>&1 || die "$key is not an SSH public key"
  case "$(awk '{print $1}' "$key")" in
    ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp256|sk-ecdsa-sha2-nistp256@openssh.com) ;;
    ssh-rsa) [ "$(ssh-keygen -lf "$key" | awk '{print $1}')" -ge 3072 ] || die "$key: an RSA key must have 3072 bits or more" ;;
    *) die "$key: use an ed25519 key (ssh-keygen -t ed25519)" ;;
  esac
  say "$name: $(ssh-keygen -lf "$key" | awk '{print $2, $NF}')"
  id "$name" >/dev/null 2>&1 || run useradd --create-home --shell /bin/bash "$name"
  run usermod -aG sudo "$name"
  if $apply; then
    install -d -m 700 -o "$name" -g "$name" "/home/$name/.ssh"
    touch "/home/$name/.ssh/authorized_keys"
    grep -qxF "$(cat "$key")" "/home/$name/.ssh/authorized_keys" || cat "$key" >> "/home/$name/.ssh/authorized_keys"
    chown "$name:$name" "/home/$name/.ssh/authorized_keys"; chmod 600 "/home/$name/.ssh/authorized_keys"
  else
    say "would add the key to /home/$name/.ssh/authorized_keys"
  fi
  users+=("$name")
done

# 2. Firewall first: the new port opens before SSH moves to it; with --allow only the named addresses reach it
ssh_port="${port:-22}"
if [ -n "$allow" ]; then
  IFS=, read -ra nets <<< "$allow"
  for n in "${nets[@]}"; do run ufw allow from "$n" to any port "$ssh_port" proto tcp; done
  say "SSH is reached only from: $allow (the old open rule is removed with --close-port)"
else
  run ufw allow "$ssh_port/tcp"
fi
run ufw limit "$ssh_port/tcp"

# 3. Second factor (optional): a code from an authenticator app after the key; each admin enrols it themselves
methods="publickey"
if $totp; then
  run apt-get install -y libpam-google-authenticator
  if $apply && ! grep -q pam_google_authenticator /etc/pam.d/sshd; then
    sed -i 's/^@include common-auth/# @include common-auth  (masslak: the key replaces the password)/' /etc/pam.d/sshd
    echo "auth required pam_google_authenticator.so" >> /etc/pam.d/sshd
  fi
  methods="publickey,keyboard-interactive"
  say "each admin runs 'google-authenticator -t -d -f -r 3 -R 30 -w 3' once, signed in as themselves, before the next session"
fi

# 4. The banner shown before every sign-in
# (the owner's own wording, in Arabic too, comes from --banner-file: a text file written on the server)
banner_text="Authorised access only. Every session on this server is recorded; unauthorised use is prosecuted."
if [ -n "$banner_file" ]; then [ -f "$banner_file" ] || die "no banner file $banner_file"; banner_text="$(cat "$banner_file")"; fi
if $apply; then printf '%s\n' "$banner_text" > "$BANNER"; else say "would write the banner to $BANNER"; fi

# 5. The settings, checked before SSH reloads
settings="# Written by deploy/ssh-harden.sh (wave 9). Remove this file and reload ssh to undo.
${port:+Port $port
}PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication $($totp && echo yes || echo no)
PubkeyAuthentication yes
AuthenticationMethods $methods
UsePAM yes
AllowUsers ${users[*]}
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
Banner $BANNER
LogLevel VERBOSE"
if $apply; then
  install -d -m 700 "$BACKUP_DIR"
  [ -f "$BACKUP_DIR/sshd_config" ] || cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config"
  [ -f "$CONF" ] && [ ! -f "$BACKUP_DIR/10-masslak.conf" ] && cp "$CONF" "$BACKUP_DIR/10-masslak.conf"
  grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config || die "/etc/ssh/sshd_config does not include sshd_config.d"
  printf '%s\n' "$settings" > "$CONF"
  sshd -t || { rm -f "$CONF"; die "sshd -t refused the settings; nothing was reloaded"; }
  [ -f /etc/fail2ban/jail.d/sshd.local ] || [ -z "$port" ] || printf '[sshd]\nenabled = true\nport = %s\n' "$port" > /etc/fail2ban/jail.d/sshd.local
  systemctl reload ssh
  systemctl restart fail2ban 2>/dev/null || true
  echo "Done. Keep this window open and sign in from a new one: ssh -p $ssh_port ${users[0]}@<server>"
  echo "When every admin has signed in, close the old port: sudo ./deploy/ssh-harden.sh --close-port 22 --apply"
else
  echo "Settings that would be written to $CONF:"
  printf '%s\n' "$settings" | sed 's/^/    /'
fi
