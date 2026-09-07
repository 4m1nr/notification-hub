# End-to-end setup

Order matters here. Each section explains why it comes where it does.

## 0. Before you start

- A VPS running **Ubuntu 26.04** with a public IP and root access.
- An office PC running **Ubuntu**, always on, inside the corporate network.
- DNS **A records already pointing at the VPS** for each domain you will use:
  `ntfy`, `rss`, `watch`, `checks`, and `logs` if you want remote syslog.
  Certificates cannot be issued before DNS resolves.
- Ports 80 and 443 reachable from the internet (80 is needed for ACME), plus
  6514 if you are collecting syslog from other machines.
- An Android phone with the **ntfy** app.
- A Telegram bot (from `@BotFather`) and a **private** chat or channel for it.

## 1. Configuration

```bash
git clone <this repo> && cd Notification-Hub

sudo install -d -m 0750 /etc/notification-hub
sudo install -m 0600 .env.example /etc/notification-hub/hub.env
sudo "${EDITOR:-vi}" /etc/notification-hub/hub.env
```

Fill in the domains and `ACME_EMAIL`. Leave everything under "Generated
automatically" alone — the installers append those on first run and reuse them
afterwards, which is what makes re-running safe.

## 2. Backup encryption key — do this now, not later

Generate it **off the VPS**. That is the whole point: if the VPS is compromised,
the attacker must not be able to read the backups they can see.

```bash
# On your laptop
age-keygen -o backup-key.txt
```

Copy the `public key:` line into `AGE_RECIPIENT` in `hub.env`, and store
`backup-key.txt` in a password manager. Without it, the backups are unrecoverable.

## 3. Base, database, ntfy, Miniflux

```bash
sudo ./bootstrap.sh 10-packages.sh 20-postgres.sh 30-ntfy.sh 40-miniflux.sh 50-go-services.sh
```

This installs packages and Docker, provisions the three PostgreSQL databases with
generated passwords, installs ntfy and creates its users and per-source tokens,
installs Miniflux and runs its migrations, and builds and starts the RSS relay.

Everything is still on loopback — nothing is reachable from outside yet. Confirm:

```bash
systemctl is-active ntfy miniflux rss-relay postgresql
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8181/healthz   # 200
```

Save the credentials it generated:

```bash
sudo grep -E '^(NTFY_PHONE_PASSWORD|MINIFLUX_ADMIN_)' /etc/notification-hub/hub.env
```

## 4. Certificates

Install the automation first, so the deploy hook is in place before the first
issuance:

```bash
sudo ./bootstrap.sh 70-certs.sh
sudo "${EDITOR:-vi}" /etc/notification-hub/domains.map
```

Uncomment and edit the lines for your domains. The columns are documented in the
file; briefly:

```
# domain            dest                     owner:group    format  service
ntfy.example.com    /etc/certs/proxy/ntfy    root:haproxy   both    haproxy
logs.example.com    /etc/certs/syslog        root:syslog    split   rsyslog
```

Now issue them. Port 80 must be free — HAProxy is not running yet, which is
exactly why this step comes before it:

```bash
sudo certbot certonly --standalone --agree-tos --email you@example.com \
  -d ntfy.example.com -d rss.example.com -d watch.example.com -d checks.example.com

sudo /opt/notification-hub/bin/distribute-certs.sh
ls -l /etc/certs/proxy/combined/
```

Note that `distribute-certs.sh` queued a restart rather than performing one —
check `/var/lib/notification-hub/pending-restart/`. That is the intended
behaviour; see [architecture.md](architecture.md).

## 5. HAProxy — the point where things become reachable

```bash
sudo ./bootstrap.sh 80-haproxy.sh
curl -sI https://ntfy.example.com | head -1
```

If HAProxy refuses to start, the cause is almost always the certificate
directory: `/etc/certs/proxy/combined/` must contain only `.pem` files, never a
subdirectory.

## 6. Set up the phone

Do this before the remaining services, so you can see each one working as you
install it. Follow [ntfy-topics.md](ntfy-topics.md): add the server, log in as
`phone`, subscribe to all seven topics.

Test it:

```bash
source /etc/notification-hub/hub.env
curl -H "Authorization: Bearer $NTFY_TOKEN_MAIL" -H "Content-Type: application/json" \
     -d '{"topic":"mail","title":"Test","message":"Hello"}' "$NTFY_URL"
```

## 7. changedetection.io and healthchecks.io

```bash
sudo ./bootstrap.sh 90-docker-apps.sh
cd /etc/notification-hub/docker && sudo docker compose exec healthchecks ./manage.py createsuperuser
```

Then work through [healthchecks-setup.md](healthchecks-setup.md): create the five
checks, copy their ping URLs into `hub.env`, and wire the ntfy integration to the
`system` topic.

```bash
sudo systemctl restart rss-relay hc-heartbeat.timer
```

For website monitoring, [changedetection-login.md](changedetection-login.md)
covers Browser Steps and getting past login gates.

## 8. Syslog

This comes after certificates because the TLS listener needs one:

```bash
sudo ./bootstrap.sh 60-syslog.sh
logger -p user.warning "hub test warning"     # should notify
logger -p user.info    "hub test info"        # should NOT notify
```

To forward from another machine, copy `vps/syslog/client-example.conf` to it as
`/etc/rsyslog.d/90-forward-to-hub.conf`, adjust the target and certificates, and
restart rsyslog there.

## 9. Backups

```bash
sudo ./bootstrap.sh 95-backup.sh
sudo /opt/notification-hub/bin/backup.sh --dry-run
```

The dry run stages, archives and encrypts, but does not upload. Verify the result
round-trips before trusting it:

```bash
age -d -i backup-key.txt /var/backups/notification-hub/backup-*.tar.gz.age | tar tzf - | head
```

Then run it for real and confirm the archive appears in your Telegram chat:

```bash
sudo systemctl start backup.service
journalctl -u backup.service -n 50
```

## 10. Office PC

On the office machine:

```bash
git clone <this repo> && cd Notification-Hub
sudo ./office-pc/install.sh
```

It builds both watchers, installs the units, masks the sleep targets, and seeds
two env files. Fill them in — including the ntfy tokens and healthchecks ping
URLs from the VPS's `hub.env`:

```bash
sudo "${EDITOR:-vi}" /etc/notification-hub/mail-watcher.env
sudo "${EDITOR:-vi}" /etc/notification-hub/mattermost-watcher.env
sudo systemctl restart mail-watcher mattermost-watcher
journalctl -u mail-watcher -f
```

For the Mattermost token: **Profile → Security → Personal Access Tokens → Create**.
If the option is absent, PATs are disabled for your account and an admin must
enable them.

Confirm the machine cannot suspend:

```bash
systemctl status sleep.target | head -3     # should say: masked
```

## 11. Verify the whole thing

```bash
# Everything up
systemctl is-active ntfy miniflux rss-relay haproxy rsyslog postgresql
systemctl list-timers 'cert-*' backup.timer hc-heartbeat.timer

# Topics are not publicly readable
curl -s -o /dev/null -w '%{http_code}\n' https://ntfy.example.com/mail/json?poll=1   # 403

# The relay rejects an unsigned webhook
curl -s -o /dev/null -w '%{http_code}\n' -X POST -d '{}' http://127.0.0.1:8181/webhook  # 401

# Certificates are placed with the right modes
sudo find /etc/certs -name 'privkey.pem'   -exec stat -c '%a %n' {} \;   # 640
sudo find /etc/certs -name 'fullchain.pem' -exec stat -c '%a %n' {} \;   # 644

# A reload is a reload, not a restart
systemctl show haproxy -p ExecMainStartTimestamp
sudo /opt/notification-hub/bin/apply-pending-restarts.sh
systemctl show haproxy -p ExecMainStartTimestamp    # unchanged

# The dead-man's-switch fires
sudo systemctl stop mail-watcher    # on the office PC; alert within ~15 min
```

## Day-to-day

```bash
# What is scheduled
systemctl list-timers

# Recent activity for one component
journalctl -u rss-relay -n 100
journalctl -u backup.service --since yesterday

# Containers
sudo docker compose -f /etc/notification-hub/docker/docker-compose.yml ps

# After editing anything in the repo, re-run just that step
sudo ./bootstrap.sh 80-haproxy.sh
```
