# VPS deployment runbook

Follow this top to bottom. Every step says what it does, what it prints that you
need to keep, and how to check it worked before moving on.

The install is broken into numbered steps you run individually. That is
deliberate: three of them need you to do something in between (edit a table,
issue certificates, create checks). Every step is idempotent, so re-running one
after a fix is safe.

**If this VPS already runs other things**, nothing here rewrites your ufw policy,
your fail2ban jails, or a HAProxy config it did not write, and step 3 aborts if
something already holds a port it needs. See
[security.md § Coexisting](security.md).

---

## 0. Before you start

**On the VPS:**

- Ubuntu 26.04, root or sudo.
- Ports 80 and 443 reachable from the internet. Nothing else needs opening.

**DNS** — four A records pointing at the VPS, resolving *before* you start.
Certificates cannot be issued otherwise:

| Record | Purpose |
|---|---|
| `ntfy.example.com` | notification delivery to your phone |
| `rss.example.com` | Miniflux, managed from the phone |
| `watch.example.com` | changedetection.io |
| `checks.example.com` | healthchecks.io |

**Elsewhere:**

- The **ntfy** app on your phone.
- A Telegram bot (message `@BotFather`) and a **private** chat or channel for it.
- `age` on your laptop, for the backup key in step 2.

Check DNS before going further:

```bash
for d in ntfy rss watch checks; do
  printf '%-24s %s\n' "$d.example.com" "$(dig +short "$d.example.com" | tail -1)"
done
```

All four must show your VPS's address.

---

## 1. Get the code and write the config

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/4m1nr/notification-hub.git
cd notification-hub

sudo install -d -m 0750 /etc/notification-hub
sudo install -m 0600 .env.example /etc/notification-hub/hub.env
sudo "${EDITOR:-vi}" /etc/notification-hub/hub.env
```

Fill in **only** these now:

```bash
NTFY_DOMAIN=ntfy.example.com
MINIFLUX_DOMAIN=rss.example.com
CD_DOMAIN=watch.example.com
HC_DOMAIN=checks.example.com
ACME_EMAIL=you@example.com

SSH_PORT=22                 # must match what sshd actually listens on
FAIL2BAN_IGNOREIP=          # your home/office IPs, space-separated
```

Leave everything under *"Generated automatically"* alone — the installers append
those on first run and reuse them afterwards, which is what makes re-runs safe.

> **`FAIL2BAN_IGNOREIP` is worth filling in now.** Without it, a mistyped password
> from home can get your own address banned for an hour.

---

## 2. Create the backup encryption key — on your laptop, not the VPS

This is the one secret that must never live on the VPS. If the VPS is
compromised, the attacker can see the backups but must not be able to read them.

```bash
# On your laptop
age-keygen -o backup-key.txt
```

Copy the `public key:` line into `AGE_RECIPIENT` in `hub.env`, and store
`backup-key.txt` in a password manager. **Without it the backups are
unrecoverable.**

While you are in the file, add the Telegram values:

```bash
AGE_RECIPIENT=age1...
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=-100...
```

To find the chat id: add the bot to the private chat, send it a message, then
open `https://api.telegram.org/bot<TOKEN>/getUpdates`.

---

## 3. Preflight, packages, firewall

```bash
sudo ./bootstrap.sh 05-preflight.sh 10-packages.sh 15-firewall.sh
```

**Preflight** stops before anything is installed if another process holds a port
the stack wants, and names the process. `8080` and `5000` are commonly taken. If
it complains, change the matching port in `hub.env` — they are all loopback-only
and free to move — and re-run:

```bash
NTFY_PORT=2586
MINIFLUX_PORT=8080
CD_PORT=5000
HC_PORT=8000
```

**The firewall step is additive.** It adds allow rules for 80 and 443 and prints
recommendations for the rest. It will not change your default policy, enable ufw,
or delete a rule. To apply the hardening once you have checked it against your
other services:

```bash
sudo /opt/notification-hub/bin/firewall.sh --dry-run   # see exactly what it would do
sudo /opt/notification-hub/bin/firewall.sh --harden
```

**Check:**

```bash
sudo ufw status verbose      # 80 and 443 allowed
docker --version && go version
```

---

## 4. Database, ntfy, Miniflux, relay

```bash
sudo ./bootstrap.sh 20-postgres.sh 30-ntfy.sh 40-miniflux.sh 50-go-services.sh
```

This creates three PostgreSQL databases with generated passwords, installs ntfy
and creates its users and per-source tokens, installs Miniflux and runs its
migrations, and builds and starts the RSS relay.

**Keep what step 30 prints** — the ntfy tokens are shown once. They are also
saved to `hub.env`:

```bash
sudo grep -E '^(NTFY_PHONE_PASSWORD|NTFY_TOKEN_|MINIFLUX_ADMIN_)' /etc/notification-hub/hub.env
```

**Check** (everything is still loopback-only; nothing is reachable from outside
yet):

```bash
systemctl is-active postgresql ntfy miniflux rss-relay
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8181/healthz     # 200
sudo -u postgres psql -c '\l' | grep -E 'ntfy|miniflux|healthchecks'       # 3 databases
```

---

## 5. Certificates

Install the automation **first**, so the deploy hook is in place before the first
certificate exists:

```bash
sudo ./bootstrap.sh 70-certs.sh
sudo "${EDITOR:-vi}" /etc/notification-hub/domains.map
```

Uncomment and edit one line per domain. The columns are documented in the file:

```
# domain            dest                      owner:group    format  service
ntfy.example.com    /etc/certs/proxy/ntfy     root:haproxy   both    haproxy
rss.example.com     /etc/certs/proxy/rss      root:haproxy   both    haproxy
watch.example.com   /etc/certs/proxy/watch    root:haproxy   both    haproxy
checks.example.com  /etc/certs/proxy/checks   root:haproxy   both    haproxy
```

> Do **not** add TLS-passthrough domains here, and do not add the syslog
> collector. Passthrough domains present their own certificates, and the
> collector uses a self-signed one on a loopback socket.

Now issue them. This first issuance needs port 80, and HAProxy is not running
yet — which is exactly why this step comes before it:

```bash
sudo certbot certonly --standalone --agree-tos --email you@example.com \
  -d ntfy.example.com -d rss.example.com -d watch.example.com -d checks.example.com

sudo /opt/notification-hub/bin/distribute-certs.sh
```

**Check:**

```bash
ls -l /etc/certs/proxy/combined/                       # one .pem per domain, mode 640
ls /var/lib/notification-hub/pending-restart/          # a queued 'haproxy' flag
```

That flag is correct. The deploy hook never restarts anything — a separate daily
timer applies queued changes, so a 3am renewal cannot cause a 3am restart.

> **Renewals do not stop HAProxy.** certbot binds `ACME_HTTP_PORT` (8402) and
> HAProxy forwards the challenge to it, so `:80` stays owned by the proxy and
> other services behind it are never interrupted.

---

## 6. HAProxy — the point where things become reachable

```bash
sudo ./bootstrap.sh 80-haproxy.sh
```

**Keep what it prints**: the admin UI username and password. changedetection.io
has no authentication of its own, so HAProxy gates it — and the healthchecks web
UI — behind HTTP basic auth.

If this box already had a HAProxy config, it is backed up to
`/etc/haproxy/haproxy.cfg.pre-notification-hub.<timestamp>` and you are told.
Anything it routed that this config does not must be added back — for TLS
passthrough, that is step 7; for anything else, merge it into
`vps/haproxy/haproxy.cfg.tmpl` and re-run. **Never edit the live file**, it is
regenerated every time.

**Check:**

```bash
curl -sI https://ntfy.example.com | head -1                                    # 200/401
curl -s -o /dev/null -w '%{http_code}\n' https://watch.example.com/            # 401
curl -s -o /dev/null -w '%{http_code}\n' -k -H 'Host: nope.invalid' https://127.0.0.1/  # 421
```

If HAProxy will not start, it is almost always the certificate directory:
`/etc/certs/proxy/combined/` must contain only `.pem` files, never a
subdirectory.

---

## 7. Other services already on this box

If the VPS proxies other domains on `:443`, add them now. Their traffic is passed
through with the TLS handshake untouched, so they keep terminating their own TLS:

```bash
sudo /opt/notification-hub/bin/passthrough.sh add servenet.example.com 127.0.0.1:441
sudo /opt/notification-hub/bin/passthrough.sh add mooz.example.com     127.0.0.1:440
sudo /opt/notification-hub/bin/passthrough.sh list
```

The table lives at `/etc/haproxy/passthrough.conf` and is **not** in the
repository, so a `git pull` can never overwrite your routing. Each `add`
validates the whole configuration and reloads — a reload, so existing sessions
survive — and refuses to apply anything that does not validate.

`list` flags a target with nothing listening behind it. Full detail in
[tls-passthrough.md](tls-passthrough.md).

---

## 8. Set up your phone

Do this before the remaining services, so you can watch each one arrive.

1. Install **ntfy**, set the default server to `https://ntfy.example.com`.
2. **Settings → Manage users → Add user**: `phone`, with `NTFY_PHONE_PASSWORD`
   from `hub.env`.
3. Subscribe to all seven topics: `mail`, `mattermost`, `rss`, `syslog`,
   `site-changes`, `system`, `backup`.
4. Exclude ntfy from battery optimisation, or Android will kill its connection.

**Check** — this should buzz your phone:

```bash
source /etc/notification-hub/hub.env
curl -H "Authorization: Bearer $NTFY_TOKEN_MAIL" -H "Content-Type: application/json" \
     -d '{"topic":"mail","title":"Test","message":"Hello from the VPS"}' "$NTFY_URL"

# And this must be refused — topics are not publicly readable
curl -s -o /dev/null -w '%{http_code}\n' "$NTFY_URL/mail/json?poll=1"          # 403
```

---

## 9. changedetection.io and healthchecks.io

```bash
sudo ./bootstrap.sh 90-docker-apps.sh
cd /etc/notification-hub/docker
sudo docker compose exec healthchecks ./manage.py createsuperuser
cd -
```

Both are behind the basic auth from step 6. Also set a password *inside*
changedetection (**Settings → Password**) so it is not relying on the proxy
alone.

Now create the checks. Log in to `https://checks.example.com/` and add five,
per [healthchecks-setup.md](healthchecks-setup.md):

| Check | Period | Grace |
|---|---|---|
| `mail-watcher` | 10 min | 5 min |
| `mattermost-watcher` | 10 min | 5 min |
| `rss-relay` | 10 min | 5 min |
| `syslog` | 10 min | 5 min |
| `backup` | 1 day | 2 hours |

Copy each ping URL into `hub.env`:

```bash
sudo "${EDITOR:-vi}" /etc/notification-hub/hub.env
# HC_PING_URL_MAIL=https://checks.example.com/ping/<uuid>
# HC_PING_URL_MATTERMOST=...
# HC_PING_URL_RSS=...
# HC_PING_URL_SYSLOG=...
# HC_PING_URL_BACKUP=...

sudo systemctl restart rss-relay
```

Then wire healthchecks to ntfy: **Integrations → Add Integration → ntfy**, server
`https://ntfy.example.com`, topic `system`, token `NTFY_TOKEN_SYSTEM` from
`hub.env`, down-priority 5. Send a test notification, then enable it on each
check.

---

## 10. Syslog and fail2ban

```bash
sudo ./bootstrap.sh 60-syslog.sh 85-fail2ban.sh
```

The collector binds `127.0.0.1`, so it takes logs from this machine only — nobody
else can inject alerts into it.

fail2ban jails are added alongside any you already run. The drop-in defines only
`nh-*` jails, carries no `[DEFAULT]` section (which would rewrite every existing
jail), adds no `sshd` jail, and reloads rather than restarts so current bans
survive. The step verifies its filters against known-good sample lines and
**fails the install** if they match nothing.

**Check:**

```bash
logger -p user.warning "hub deploy test"     # should notify
logger -p user.info    "hub deploy test"     # should NOT notify

ss -ltn | grep 6514                          # 127.0.0.1:6514 only
sudo fail2ban-client status                  # nh-haproxy-auth and nh-haproxy-abuse present
```

---

## 11. Backups

```bash
sudo ./bootstrap.sh 95-backup.sh
sudo /opt/notification-hub/bin/backup.sh --dry-run
```

The dry run stages, archives and encrypts but does not upload. **Verify it
round-trips before trusting it** — on your laptop, with the key from step 2:

```bash
age -d -i backup-key.txt /path/to/backup-*.tar.gz.age | tar tzf - | head -20
```

You should see three `postgres/*.dump` files, `changedetection/`, `config/` and
`MANIFEST.txt`. Then run it for real:

```bash
sudo systemctl start backup.service
journalctl -u backup.service -n 30
```

The encrypted archive should appear in your Telegram chat.

---

## 12. Final verification

```bash
# Services
systemctl is-active postgresql ntfy miniflux rss-relay haproxy rsyslog fail2ban
systemctl list-timers 'cert-*' backup.timer hc-heartbeat.timer

# Nothing unintended is exposed
sudo ss -ltn | grep -vE '127\.0\.0\.1|\[::1\]'

# Auth boundaries hold
curl -s -o /dev/null -w 'ntfy anon:   %{http_code}\n' https://ntfy.example.com/mail/json?poll=1   # 403
curl -s -o /dev/null -w 'watch anon:  %{http_code}\n' https://watch.example.com/                  # 401
curl -s -o /dev/null -w 'checks ping: %{http_code}\n' https://checks.example.com/ping/test        # not 401
curl -s -o /dev/null -w 'relay unsigned: %{http_code}\n' -X POST -d '{}' http://127.0.0.1:8181/webhook  # 401

# Certificate permissions
sudo find /etc/certs -name 'privkey.pem'   -exec stat -c '%a %n' {} \;   # 640
sudo find /etc/certs -name 'fullchain.pem' -exec stat -c '%a %n' {} \;   # 644

# A reload is a reload, not a restart
systemctl show haproxy -p ExecMainStartTimestamp
sudo /opt/notification-hub/bin/apply-pending-restarts.sh
systemctl show haproxy -p ExecMainStartTimestamp    # unchanged
```

---

## 13. The office PC

A separate machine, also Ubuntu, inside the corporate network. It needs only
outbound HTTPS to the VPS — no VPN.

```bash
git clone https://github.com/4m1nr/notification-hub.git && cd notification-hub
sudo ./office-pc/install.sh
```

This builds both watchers as static binaries, installs their systemd units, masks
the sleep targets, and seeds two env files. It deliberately does not start a
watcher whose credentials are still blank.

Fill them in, copying `NTFY_URL`, `NTFY_TOKEN_MAIL`, `NTFY_TOKEN_MATTERMOST` and
the two `HC_PING_URL_*` values from the VPS's `hub.env`:

```bash
sudo "${EDITOR:-vi}" /etc/notification-hub/mail-watcher.env
sudo "${EDITOR:-vi}" /etc/notification-hub/mattermost-watcher.env
sudo systemctl restart mail-watcher mattermost-watcher
journalctl -u mail-watcher -f
```

For the Mattermost token: **Profile → Security → Personal Access Tokens →
Create**. If that option is absent, PATs are disabled for your account and an
admin has to enable them. No admin rights are needed beyond that.

**Check:**

```bash
systemctl is-active mail-watcher mattermost-watcher
systemctl status sleep.target | head -3      # must say: masked
```

That last one matters more than it looks: a suspended office PC is the single
most likely cause of a silently dead watcher.

**Confirm both failure paths:**

```bash
# Auto-restart: should be back within ~10s
sudo systemctl kill -s KILL mail-watcher && sleep 15 && systemctl is-active mail-watcher

# Dead-man's-switch: stop it and wait out period + grace (~15 min).
# You should get an alert on the `system` topic.
sudo systemctl stop mail-watcher
# ... wait ...
sudo systemctl start mail-watcher
```

---

## Re-running and updating

```bash
cd notification-hub && git pull
sudo ./bootstrap.sh                    # every step, in order
sudo ./bootstrap.sh 80-haproxy.sh      # or just one
```

Every step is idempotent. Generated credentials in `hub.env` are reused, never
regenerated, so re-running does not invalidate your phone's login or your tokens.

Your passthrough routing (`/etc/haproxy/passthrough.conf`) and cert table
(`/etc/notification-hub/domains.map`) live outside the repository and are never
touched by a pull.

## If something goes wrong

```bash
journalctl -u <service> -n 100         # ntfy, miniflux, rss-relay, haproxy, rsyslog
sudo docker compose -f /etc/notification-hub/docker/docker-compose.yml logs --tail 50
sudo haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d   # validate before reloading
sudo fail2ban-client status nh-haproxy-auth                          # did it ban you?
```

Banned yourself while testing? Clear it:

```bash
sudo fail2ban-client set nh-haproxy-auth unbanip <your-ip>
echo "clear table st_clients" | sudo socat stdio /run/haproxy/admin.sock
```

## Where things live

| Path | What |
|---|---|
| `/etc/notification-hub/hub.env` | every credential and setting (0600) |
| `/etc/notification-hub/domains.map` | certificate distribution table |
| `/etc/haproxy/passthrough.conf` | TLS passthrough routing (not in git) |
| `/opt/notification-hub/bin/` | built binaries and operational scripts |
| `/var/lib/notification-hub/pending-restart/` | queued certificate restarts |
| `/var/backups/notification-hub/` | last 3 encrypted archives |
| `/etc/certs/` | distributed certificates, per service |
