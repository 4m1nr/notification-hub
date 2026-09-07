# The dead-man's-switch

The design constraint: **no "still alive" pings on your phone.** Silence is the
signal. You should hear from this system when a watcher *stops*, not while it is
working.

healthchecks.io inverts the usual alerting model to do that. Each watcher pings a
URL on a timer; if a ping does not arrive within its period plus grace, the check
goes red and healthchecks notifies the `system` topic. Nothing is sent while
everything is fine.

## First-time setup

```bash
cd /etc/notification-hub/docker
sudo docker compose exec healthchecks ./manage.py createsuperuser
```

Then log in at `https://checks.example.com/`. Registration is closed, so this
superuser is the only account.

## Creating the checks

Create one check per watcher, under **Add Check**:

| Check name | Period | Grace | Pinged by |
|---|---|---|---|
| `mail-watcher` | 10 min | 5 min | Office PC, while the IMAP connection is up |
| `mattermost-watcher` | 10 min | 5 min | Office PC, while the WebSocket is up |
| `rss-relay` | 10 min | 5 min | VPS `hc-heartbeat.timer` |
| `syslog` | 10 min | 5 min | VPS `hc-heartbeat.timer` |
| `backup` | 1 day | 2 hours | The backup job, on success |

The watchers ping every 5 minutes (`HC_INTERVAL`), so a 10-minute period tolerates
one missed ping — a brief network blip should not page you — while 5 minutes of
grace bounds how long a genuinely dead watcher stays unnoticed at roughly 15
minutes.

The `backup` check is different: a daily job needs a period of one day, and its
grace only needs to cover a slow upload.

Copy each check's ping URL into `/etc/notification-hub/hub.env`:

```bash
HC_PING_URL_MAIL=https://checks.example.com/ping/<uuid>
HC_PING_URL_MATTERMOST=https://checks.example.com/ping/<uuid>
HC_PING_URL_RSS=https://checks.example.com/ping/<uuid>
HC_PING_URL_SYSLOG=https://checks.example.com/ping/<uuid>
HC_PING_URL_BACKUP=https://checks.example.com/ping/<uuid>
```

The office-PC watchers read `HC_PING_URL_MAIL` / `HC_PING_URL_MATTERMOST` from
their own env files — copy those two values over to the office PC as well.

Restart what needs restarting:

```bash
# VPS
sudo systemctl restart rss-relay hc-heartbeat.timer
# Office PC
sudo systemctl restart mail-watcher mattermost-watcher
```

An empty ping URL disables that check. The service still runs — it just has no
backstop.

## Wiring alerts to ntfy

healthchecks has a built-in ntfy integration, available because the container
sets `NTFY_ENABLED=True`. Without that variable the integration does not appear in
the UI at all.

1. **Integrations → Add Integration → ntfy**
2. Fill in:
   - **Server URL**: `https://ntfy.example.com`
   - **Topic**: `system`
   - **Access token**: the value of `NTFY_TOKEN_SYSTEM` from `hub.env`
   - **Priority (down)**: 5 — this is the alert you must not miss
   - **Priority (up)**: 1 or "disabled" — a recovery notice is nice, but it
     should not wake you
3. **Save**, then use **Send Test Notification** to confirm it reaches the phone.
4. Go back to each check and enable the ntfy integration on it.

## How each watcher decides to ping

This is the part that is easy to get wrong.

**The watchers are event-driven.** A Mattermost channel can be legitimately quiet
all night; a mailbox can go untouched over a weekend. Pinging on message receipt
would take the check down every evening and train you to ignore it.

So the ping comes from a background timer that is *gated on the connection being
alive*:

- `mail-watcher` and `mattermost-watcher` run an `hc.Heartbeat` goroutine that
  pings every `HC_INTERVAL`, but only while the IMAP/WebSocket session is
  actually established. Lose the connection and the pings stop immediately, even
  though the process is still running.
- On the VPS, `hc-heartbeat.timer` checks that `rss-relay` is active *and*
  answering on `/healthz`, and that `rsyslog` is active, before pinging. A timer
  that pings unconditionally is monitoring the timer, not the service.

## What this catches, and what auto-restart catches

They are different failures, and both matter:

| Failure | Caught by |
|---|---|
| Process crashed | systemd `Restart=always` — back in 10s, no alert |
| Process wedged, connection dead | The heartbeat's `Alive` gate → check goes red |
| Office PC suspended or powered off | No pings at all → check goes red |
| Network partition | No pings → check goes red |
| systemd itself gave up | `StartLimitIntervalSec=0` prevents this; check is the backstop |

The units set `StartLimitIntervalSec=0` on purpose: systemd's default would stop
restarting after five rapid failures and leave a watcher dead until someone
noticed. The dead-man's-switch exists for machines that are *off*, not for
healthy machines where systemd quietly gave up.

## Testing it

```bash
# On the office PC
sudo systemctl stop mail-watcher
# Wait out period + grace (~15 min) → alert on the `system` topic
sudo systemctl start mail-watcher
# Check returns to green, and the "up" notification arrives if enabled

# Confirm auto-restart works independently
sudo systemctl kill -s KILL mail-watcher
sleep 15 && systemctl is-active mail-watcher   # should print "active"
```
