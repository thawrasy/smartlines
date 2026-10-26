# SSH on the server (wave 9)

Wave 9 closes the server's own door: who signs in over SSH, how, and from where. It changes no code or schema and is
applied with the owner present at production, with `deploy/ssh-harden.sh`. The trial server keeps its current access
until then.

## Principles

- **One account per person.** Every administrator signs in as themselves; root never signs in. What each person did is
  in the logs under their name, and removing a person removes one account.
- **Keys only.** Each person makes an ed25519 key on their own computer (`ssh-keygen -t ed25519 -C name@masslak`),
  protects it with a passphrase and hands over only the public half (`.pub`). Nobody sends, stores or asks for a private
  key or a password; the script refuses a private key file.
- **Never locked out.** The script opens the new port in the firewall before SSH moves to it, checks the settings with
  `sshd -t` before reloading, keeps the session it runs in and keeps the old port until `--close-port`. The hosting
  provider's console stays the last way in.

## Steps

| # | Step | Command |
|---|---|---|
| 1 | Each administrator makes their key and sends the `.pub` | `ssh-keygen -t ed25519 -C name@masslak` |
| 2 | Dry run: read what would change | `sudo ./deploy/ssh-harden.sh --admin name:/root/keys/name.pub --port 2222` |
| 3 | Apply, in a session kept open | the same command with `--apply` |
| 4 | Each administrator signs in from a new window | `ssh -p 2222 name@server` then `sudo -v` |
| 5 | Optional second factor: each enrols once | `google-authenticator -t -d -f -r 3 -R 30 -w 3` (after `--totp`) |
| 6 | Close the old port | `sudo ./deploy/ssh-harden.sh --close-port 22 --apply` |
| 7 | Check from outside | `ssh root@server` is refused; `ssh -o PreferredAuthentications=password name@server` is refused |

`--allow 203.0.113.0/24,198.51.100.7` limits SSH to the named addresses (an office, a VPN); `--banner-file` shows the
owner's own wording before sign-in. `--rollback --apply` restores the SSH settings found before the first run and
leaves the accounts in place.

## What the settings say

`/etc/ssh/sshd_config.d/10-masslak.conf`: the chosen port, `PermitRootLogin no`, `PasswordAuthentication no`,
`AuthenticationMethods publickey` (plus `keyboard-interactive` with `--totp`), `AllowUsers` the named accounts,
`MaxAuthTries 3`, `LoginGraceTime 30`, idle sessions closed after ten minutes, no X11, TCP or agent forwarding, the
banner and verbose logging. fail2ban watches the new port.

## Adding and removing a person

- Add: run the script again with every current `--admin` and the new one.
- Remove: `sudo userdel -r name`, then run the script with the remaining `--admin` entries so `AllowUsers` drops the
  name.
- A lost or exposed key: remove its line from `/home/name/.ssh/authorized_keys` at once; the person makes a new key.
