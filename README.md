# Notification Hub

One Android notification stream for a pile of unrelated alert sources: office
mail, office Mattermost, RSS, system logs, website changes, backup failures,
and "a watcher has gone quiet".

Everything is self-hosted. Nothing routes through a third-party push service you
do not control, and the phone talks to exactly one endpoint.

## What runs where

```
┌───────────────────────── VPS (Ubuntu 26.04, public) ─────────────────────────┐
│                                                                              │
│   fail2ban bans repeat offenders · ufw rules added, never rewritten           │
│   HAProxy :443 ── SNI ──┬─ passthrough ──▶ other services already on this box │
│                         ├─ unknown name ──▶ silent-drop                       │
│                         └─ terminate ──┬──▶ ntfy            127.0.0.1:2586   │
│                                        ├──▶ Miniflux        127.0.0.1:8080   │
│                                        ├──▶ changedetection 127.0.0.1:5000   │
│                                        └──▶ healthchecks    127.0.0.1:8000   │
│                                                                              │
│   PostgreSQL (unix socket only) ── ntfy · miniflux · healthchecks databases   │
│                                                                              │
│   rsyslog (127.0.0.1 only) ──omprog──▶ syslog-ntfy ──┐                       │
│   Miniflux ──webhook──▶ rss-relay :8181 ────────┤                            │
│   changedetection ──Apprise─────────────────────┼──▶ ntfy topics             │
│   healthchecks ──built-in ntfy integration──────┤                            │
│   backup.sh (daily) ────────────────────────────┘                            │
│        └── age-encrypted tar.gz ──▶ private Telegram chat                    │
└──────────────────────────────────────────────────────────────────────────────┘

┌────────────── Office PC (Ubuntu, inside the corporate network) ──────────────┐
│   mail-watcher        IMAP IDLE ────────────┐                                │
│   mattermost-watcher  WebSocket + PAT ──────┴─── outbound HTTPS ──▶ VPS      │
│   (both ping healthchecks.io while their connection is up)                   │
└──────────────────────────────────────────────────────────────────────────────┘

                          📱 ntfy Android app, one subscription per topic
```

Topics: `mail`, `mattermost`, `rss`, `syslog`, `site-changes`, `system`, `backup`.

## Design decisions worth knowing

**Native, not containerised.** ntfy, Miniflux, PostgreSQL, HAProxy, rsyslog and
all four of our own services run as ordinary systemd units. Only
changedetection.io, its Playwright browser, and healthchecks.io are containers —
those three are Python/Chromium stacks that are genuinely painful to pin by hand.

**One PostgreSQL, three databases.** ntfy, Miniflux and healthchecks each get
their own database and their own role, and each role can connect only to its own
database. Nothing listens on TCP; the container reaches the database through a
bind-mounted unix socket. (changedetection.io is the exception — it has no SQL
backend at all and keeps a JSON datastore on disk.)

**It shares the box.** :443 is split by SNI, so services already proxied here
keep terminating their own TLS and only this project's four domains are
decrypted. Existing ufw rules, fail2ban jails and HAProxy configs are added to or
backed up, never rewritten — and `05-preflight.sh` refuses to install if
something already holds a port it wants. Every internal port is configurable.

**Nothing accepts anonymous input.** The syslog collector binds `127.0.0.1`, so
no one else can send you logs at all — rsyslog cannot authenticate remote senders
over TLS without client certificates, and a public-CA `certvalid` check would
accept a certificate issued to anyone. changedetection.io ships with no
authentication of its own, so HAProxy gates it behind basic auth. Everything
public sits behind per-IP rate limiting, sticky abuse flags, and fail2ban. See
[docs/security.md](docs/security.md).

**Silence is the alert.** No component sends "still alive" pings to your phone.
Watchers ping healthchecks.io on a timer *while their connection is up*; when one
stops, its check goes red and healthchecks notifies the `system` topic. The one
exception is the daily backup, which alerts immediately on failure rather than
waiting out a grace period — a once-daily job could otherwise lose a day
unnoticed.

**Renewals and restarts are decoupled.** Certificates are checked every 6 hours
and renewed 3 days before expiry, but nothing is restarted at that moment. The
deploy hook drops a flag file; a separate daily timer applies the changes in one
predictable window — `reload` for HAProxy, `restart` for the rest.

## Quick start (VPS)

```bash
git clone <this repo> && cd Notification-Hub

sudo install -d -m 0750 /etc/notification-hub
sudo install -m 0600 .env.example /etc/notification-hub/hub.env
sudo "${EDITOR:-vi}" /etc/notification-hub/hub.env   # domains, ACME email

# DNS for each domain must already point at this VPS.
sudo ./bootstrap.sh 05-preflight.sh 10-packages.sh 15-firewall.sh 20-postgres.sh \
                    30-ntfy.sh 40-miniflux.sh 50-go-services.sh

# Issue certificates, then let the distribution script place them.
# This first issuance needs :80 free, so run it before HAProxy starts. Renewals
# afterwards go through HAProxy and never stop it.
sudo ./bootstrap.sh 70-certs.sh
sudo "${EDITOR:-vi}" /etc/notification-hub/domains.map   # uncomment your domains
sudo certbot certonly --standalone -d ntfy.example.com --email you@example.com --agree-tos
sudo /opt/notification-hub/bin/distribute-certs.sh

# The rest.
sudo ./bootstrap.sh 80-haproxy.sh 90-docker-apps.sh 60-syslog.sh 85-fail2ban.sh 95-backup.sh
```

Every step is idempotent — re-run any of them after a fix.

## Quick start (office PC)

```bash
git clone <this repo> && cd Notification-Hub
sudo ./office-pc/install.sh
sudo "${EDITOR:-vi}" /etc/notification-hub/mail-watcher.env
sudo "${EDITOR:-vi}" /etc/notification-hub/mattermost-watcher.env
sudo systemctl restart mail-watcher mattermost-watcher
```

## Documentation

| Document | What it covers |
|---|---|
| [docs/setup.md](docs/setup.md) | Full walkthrough, in order, with the reasoning |
| [docs/architecture.md](docs/architecture.md) | How the pieces fit and why |
| [docs/ntfy-topics.md](docs/ntfy-topics.md) | Topics, tokens, subscribing the phone |
| [docs/miniflux-android.md](docs/miniflux-android.md) | Managing feeds from Android |
| [docs/healthchecks-setup.md](docs/healthchecks-setup.md) | Per-watcher checks and the ntfy integration |
| [docs/changedetection-login.md](docs/changedetection-login.md) | Watching pages behind a login |
| [docs/security.md](docs/security.md) | What's exposed, and every layer protecting it |
| [docs/backup-restore.md](docs/backup-restore.md) | Decrypting and restoring from Telegram |

## Development

```bash
make build   # all four binaries into ./bin
make check   # go vet, go test, bash -n, shellcheck, systemd-analyze
```

Our code is Go — one module, four commands, shared `internal/` packages for the
ntfy publisher and the healthchecks pinger. Both machines run Ubuntu, so it is
one toolchain and one deployment idiom throughout.

## Secrets

Nothing is hardcoded. All credentials live in `/etc/notification-hub/hub.env`
(mode 0600) on the VPS and per-service `.env` files on the office PC, all
gitignored. Generated passwords and tokens are written there on first install and
reused on every subsequent run.

The backup encryption key is the one secret that must **not** live on the VPS —
generate it elsewhere with `age-keygen` and put only the public recipient in
`hub.env`. If the VPS is lost, the backups are still readable; if the VPS is
compromised, they are not.

Set `SSH_PORT` and `FAIL2BAN_IGNOREIP` in `hub.env` before running the firewall
step — the installer refuses to enable ufw if the SSH port looks wrong, but an
empty ignore list means a mistyped password can lock you out of your own
services.
