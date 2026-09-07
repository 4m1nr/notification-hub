# Backups: what is in them, and how to restore

## What runs

`backup.service`, fired daily by `backup.timer` at `BACKUP_TIME` (default 03:30,
deliberately not the same as `CERT_RESTART_TIME`):

1. `pg_dumpall --globals-only` for role definitions, then `pg_dump -Fc` for each
   of `ntfy`, `miniflux` and `healthchecks`. Consistent snapshots, no downtime.
2. changedetection.io — the one service with no SQL backend — is stopped for a
   few seconds so its JSON datastore can be copied consistently, then restarted.
3. Configuration: ntfy `server.yml`, `miniflux.conf`, `haproxy.cfg`, the rsyslog
   drop-ins, the systemd units, `domains.map`, the cert scripts, and `hub.env`.
4. `tar czf`, then **`age` encryption**, then upload to a private Telegram chat.
5. On success, ping the `backup` check. On *any* failure, publish immediately to
   the ntfy `backup` topic and mark the check failed.

## What is deliberately **not** in them

**TLS private keys.** The script actively refuses to continue if it finds a
`*.pem` or `*.key` in the staging area. They are re-issuable from ACME in
minutes, and shipping them to a chat app buys nothing but risk. After a restore,
run certbot again.

## Why it is encrypted

The archive contains `hub.env` — ntfy tokens, database passwords, the Telegram
bot token, the Miniflux admin password. Telegram's servers are not a trusted
vault, and a private channel is private by policy, not by cryptography.

Generate the keypair **off the VPS**:

```bash
age-keygen -o backup-key.txt
# public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

Put only the public line in `AGE_RECIPIENT` in `hub.env`. Keep `backup-key.txt`
somewhere the VPS cannot reach — a password manager, an offline drive. If the VPS
is lost you can still read the backups; if the VPS is compromised, the attacker
cannot.

## The 50 MB limit

Telegram's Bot API caps document uploads at 50 MB. When the encrypted archive
exceeds ~49 MB, the script splits it with `split -b 45M -d -a 3` and uploads each
part as a separate document, captioned `part N of M`.

The alternative — self-hosting a Local Bot API Server for a 2 GB limit — is a C++
service to build and maintain for a problem that `cat` already solves. Splitting
was chosen for that reason. If archives ever grow past a handful of parts,
revisit it.

## Restoring

### 1. Reassemble and decrypt

Download the archive (or all its parts) from the Telegram chat.

```bash
# Single file
age -d -i backup-key.txt -o backup.tar.gz backup-2026-09-07.tar.gz.age

# Split into parts — concatenate in order FIRST, then decrypt. Each part is a
# fragment of one ciphertext, not an archive of its own.
cat backup-2026-09-07.tar.gz.age.part* > backup.tar.gz.age
age -d -i backup-key.txt -o backup.tar.gz backup.tar.gz.age

mkdir restore && tar xzf backup.tar.gz -C restore
cat restore/MANIFEST.txt
```

`ls` the parts before concatenating: the glob must expand in numeric order.
`split -d -a 3` produces `part000`, `part001`, … which sorts correctly.

### 2. Rebuild the host

```bash
git clone <this repo> && cd Notification-Hub
sudo install -d -m 0750 /etc/notification-hub
sudo install -m 0600 restore/config/hub.env /etc/notification-hub/hub.env
sudo ./bootstrap.sh 10-packages.sh 20-postgres.sh
```

Install the packages and create the databases, but do **not** let the services
start populating them yet.

### 3. Restore the databases

The passwords in the restored `hub.env` must match the roles, so recreate the
roles from the dump rather than letting the installer generate new ones:

```bash
sudo -u postgres psql -f restore/postgres/globals.sql

for db in ntfy miniflux healthchecks; do
  sudo -u postgres dropdb --if-exists "$db"
  sudo -u postgres createdb -O "$db" "$db"
  sudo -u postgres pg_restore -d "$db" --no-owner --role="$db" \
      "restore/postgres/${db}.dump"
done
```

### 4. Restore configuration and state

```bash
sudo install -m 0640 restore/config/domains.map /etc/notification-hub/domains.map
sudo mkdir -p /var/lib/changedetection
sudo cp -a restore/changedetection/. /var/lib/changedetection/
```

### 5. Re-issue certificates and finish

```bash
sudo ./bootstrap.sh 30-ntfy.sh 40-miniflux.sh 50-go-services.sh 70-certs.sh

# Keys were never backed up — get new ones.
sudo certbot certonly --standalone -d ntfy.example.com --email you@example.com --agree-tos
# ... repeat for each domain in domains.map ...
sudo /opt/notification-hub/bin/distribute-certs.sh

sudo ./bootstrap.sh 80-haproxy.sh 90-docker-apps.sh 60-syslog.sh 95-backup.sh
```

Your phone keeps working without reconfiguration: the ntfy users, tokens and ACLs
came back with the `ntfy` database.

## Verifying before you need it

A backup you have never restored is a hypothesis. Check it now:

```bash
sudo /opt/notification-hub/bin/backup.sh --dry-run

# Confirm the archive is complete and readable with your key
age -d -i backup-key.txt /var/backups/notification-hub/backup-*.tar.gz.age | tar tzf - | head -30

# Confirm the failure path alerts: break the token, run, expect a `backup` notification
sudo TELEGRAM_BOT_TOKEN=invalid /opt/notification-hub/bin/backup.sh
```

## Local retention

The last `BACKUP_RETENTION_DAYS` (default 3) encrypted archives stay in
`/var/backups/notification-hub`. That is a much faster restore path than pulling
from Telegram, and it is independent of whether the upload succeeded.

## Monitoring

```bash
systemctl list-timers backup.timer
journalctl -u backup.service -n 100
systemctl status backup.service
```

A failure notifies the `backup` topic immediately, naming the step that failed —
`postgres dump`, `encrypt`, `telegram upload`, and so on. It does not wait for the
dead-man's-switch, because a once-daily job could lose a full day before a grace
period lapsed.
