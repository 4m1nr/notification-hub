# Architecture

## The shape of the problem

Seven unrelated sources, three of which live inside a corporate network, one
phone, and no third-party push service. The hub pattern solves it: every source
becomes a publisher, ntfy is the single fan-in point, and the phone holds exactly
one subscription per topic to exactly one server.

```
Office PC (Ubuntu)                     VPS (Ubuntu 26.04)                Phone
─────────────────                      ──────────────────                ─────
mail-watcher      ──┐                                                       │
  IMAP IDLE         │                  ┌──────────────┐                     │
                    ├── HTTPS ────────▶│              │                     │
mattermost-watcher──┘                  │              │                     │
  WebSocket + PAT                      │     ntfy     │◀── subscribe ───────┤
                                       │              │                     │
Miniflux ──webhook──▶ rss-relay ──────▶│  7 topics    │                     │
rsyslog (local) ──omprog─▶ syslog-ntfy▶│              │                     │
changedetection ──Apprise─────────────▶│              │                     │
healthchecks ──ntfy integration───────▶│              │                     │
backup.sh ──on failure────────────────▶└──────────────┘                     │
```

## Why these boundaries

**The office PC runs the two watchers, not the VPS.** The IMAP server and
Mattermost instance are inside the corporate network. The PC is already there, so
it needs no VPN — just outbound HTTPS to the VPS, which every corporate network
allows.

**Everything else runs on the VPS.** It has a public IP for ACME and for the
phone to reach, and it is always on.

**The phone talks to one endpoint.** Adding a source never means reconfiguring
the phone — a new source is a new publisher against an existing topic.

## Native, with three exceptions

ntfy, Miniflux, PostgreSQL, HAProxy, rsyslog and our four Go services are
ordinary systemd units. Packages, binaries, unit files — things that upgrade with
`apt` and debug with `journalctl`.

Three containers remain, and the reasoning is the same for all of them: they are
Python/Chromium stacks whose dependency trees move fast and pin badly by hand.
changedetection.io, its `sockpuppetbrowser` (a packaged Chromium), and
healthchecks.io. All three publish only to `127.0.0.1`; HAProxy stays the single
TLS terminator.

## One database, three tenants

```
PostgreSQL (unix socket only — nothing listens on TCP)
├── ntfy         owned by role `ntfy`         — message cache, ACLs, tokens, web-push
├── miniflux     owned by role `miniflux`     — feeds, entries, read state
└── healthchecks owned by role `healthchecks` — check definitions, ping history
```

`REVOKE CONNECT ... FROM PUBLIC` on each database means a role can open only its
own. One leaked service credential does not expose the others.

The healthchecks container reaches this through a bind-mounted
`/var/run/postgresql`, authenticating with a password over the socket — so the
database is shared without a TCP listener ever being opened. (Peer authentication
would not work: the container's UID matches no host user.)

changedetection.io is the exception. It has no SQL backend at all — its state is a
JSON datastore on disk, bind-mounted at `/var/lib/changedetection`.

## TLS: one port, two behaviours

```
:443  frontend tls_in  (TCP mode)
        │
        ├── SNI matches a tunnel domain ──▶ passthrough, untouched
        │
        └── everything else ──▶ abns@https ──▶ frontend https_in (TLS terminated)
                                                 │
                                                 ├── Host: ntfy.*    ──▶ :2586
                                                 ├── Host: rss.*     ──▶ :8080
                                                 ├── Host: watch.*   ──▶ :5000
                                                 └── Host: checks.*  ──▶ :8000
```

The separate tunnel service terminates its own TLS for its own domains, so those
bytes must arrive untouched. Inspecting SNI before deciding is what lets one port
serve both.

Two configuration details that are load-bearing:

- **`crt` points at a directory of combined PEMs.** HAProxy loads every file in
  it and selects by SNI. A subdirectory in there is a startup error, which is why
  the per-domain split copies live in `/etc/certs/proxy/<domain>/` while the
  combined files go in `/etc/certs/proxy/combined/`.
- **ntfy's backend has a 12-hour timeout.** The Android app holds a subscription
  open indefinitely; the default 60 seconds would sever it every minute.

## Certificates: renew often, restart predictably

```
every 6h    check-cert-renewal.sh
              └─ expires within 3 days? ─▶ certbot renew --force-renewal
                                              └─ deploy hook: distribute-certs.sh
                                                   ├─ copy to each service's own path
                                                   ├─ concatenate combined PEM for HAProxy
                                                   └─ touch pending-restart/<service>
                                                      (and nothing else)

daily @04:30  apply-pending-restarts.sh
                ├─ haproxy  → systemctl reload   (zero-downtime)
                ├─ rsyslog  → systemctl restart
                └─ tunnel   → systemctl restart
```

Three properties fall out of this split:

1. **No service reads `/etc/letsencrypt/live` directly.** Each has its own path
   with its own ownership, `0640` on keys and `0644` on chains.
2. **Renewal never restarts anything.** A 3am renewal cannot cause a 3am restart.
   All changes land in one predictable daily window.
3. **A failed restart is retried.** The flag file is removed only after the
   action succeeds, so tomorrow's run picks it up rather than forgetting.

The stock `certbot.timer` is disabled, because two schedulers racing to renew the
same lineages is worse than either alone.

Adding a domain is one line in `/etc/notification-hub/domains.map`.

## Alerting: silence is the signal

No component sends "still alive" pings to the phone. Watchers ping
healthchecks.io on a timer **while their connection is up**; when the connection
drops or the machine goes away, pings stop, the check goes red, and healthchecks
publishes to the `system` topic.

The gating matters. Both office watchers are event-driven and can be legitimately
quiet for hours, so pinging on message receipt would fire false alarms nightly.
Instead a background goroutine pings on an interval, checking that the
IMAP/WebSocket session is actually established. On the VPS, `hc-heartbeat.timer`
verifies the unit is active and answering on `/healthz` before pinging — a timer
that pings unconditionally is monitoring the timer.

Auto-restart and the dead-man's-switch cover different failures:
`Restart=always` with `StartLimitIntervalSec=0` handles crashes without alerting
you; the check handles wedged connections, suspended machines, and network
partitions.

The daily backup breaks the pattern deliberately: it alerts on failure
immediately rather than waiting out a grace period, because a once-daily job
could lose a full day unnoticed.

## Security boundary

HAProxy is not just the TLS terminator, it is where abuse is stopped. Per-IP
stick tables track request rate, connection rate and — most usefully — the rate
of 4xx responses, which is what actually distinguishes credential stuffing from
ordinary traffic. Crossing that threshold sets a sticky flag, and flagged clients
are `silent-drop`ped for an hour whether or not they back off. fail2ban then
promotes repeat offenders to firewall bans that survive a HAProxy reload.

The syslog collector is bound to `127.0.0.1`. rsyslog cannot authenticate remote
senders over TLS without client certificates, and the tempting shortcut —
`x509/certvalid` against a public CA — accepts any certificate that CA ever
issued to anyone. Not listening is the honest answer.

Full detail in [security.md](security.md).

## Our code

One Go module, four commands, shared internals:

```
internal/ntfy    Publish() — JSON API, bearer token, retry with backoff.
                 Retries 5xx, fails fast on 4xx (a bad token will never succeed).
internal/hc      Ping/Start/Fail, and Heartbeat — the gated timer above.
internal/config  Env + optional .env, accumulating every error before failing.
internal/logx    slog to stderr, without a timestamp (journald adds its own).

cmd/rss-relay           Verifies the Miniflux HMAC before parsing. That signature
                        is the only auth on the endpoint.
cmd/syslog-ntfy         Long-lived omprog reader with dedup and a per-minute cap,
                        so one flapping service cannot bury the phone.
cmd/mail-watcher        IMAP IDLE, sequence-number high-water mark, expunge-aware.
cmd/mattermost-watcher  WebSocket + PAT, filters mentions / DMs / an allowlist.
```

Both machines run Ubuntu, so this is one toolchain, one build, and one deployment
idiom — a static binary plus a systemd unit with an `EnvironmentFile`.

## Failure modes and what covers them

| Failure | Covered by |
|---|---|
| A service crashes | systemd `Restart=always`, `StartLimitIntervalSec=0` |
| A watcher wedges, connection dead | Heartbeat's alive-gate → check goes red |
| The office PC suspends | `sleep.target` masked; check goes red if it happens anyway |
| Network partition | In-process backoff reconnect; check goes red if prolonged |
| Certificate about to expire | 6-hourly check, 3-day threshold, ~12 retries |
| Bad HAProxy config on reload | `haproxy -c` validates before reloading |
| Backup upload fails | Immediate ntfy alert naming the failed step |
| A log flood | Dedup window + per-minute cap in `syslog-ntfy` |
| Someone injecting fake logs | Impossible — the collector binds `127.0.0.1` |
| Credential stuffing on a public service | HAProxy 4xx-rate tracking → sticky block → fail2ban |
| changedetection's missing auth | HTTP basic auth enforced at HAProxy |
| A mail flood | Batches over 10 collapse into one summary |
| The VPS is lost entirely | Encrypted daily archive in Telegram, restorable per `backup-restore.md` |
