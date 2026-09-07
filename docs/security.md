# Security posture

What is reachable from the internet, what protects it, and where the sharp edges
are.

## What is exposed

| Port | Service | Reachable from | Authentication |
|---|---|---|---|
| 443 | HAProxy → ntfy | anywhere | ntfy token (deny-all default) |
| 443 | HAProxy → Miniflux | anywhere | Miniflux login / Fever / GReader password |
| 443 | HAProxy → changedetection | anywhere | **HTTP basic auth at the proxy** |
| 443 | HAProxy → healthchecks UI | anywhere | **HTTP basic auth at the proxy** + Django login |
| 443 | HAProxy → healthchecks `/ping/` | anywhere | the ping UUID itself |
| 80 | HAProxy | anywhere | redirect to 443; ACME challenge only |
| 22 | sshd | anywhere | your existing SSH config and jails |
| 443 | HAProxy → TLS passthrough | anywhere | handled by the backend service itself |
| 6514 | rsyslog | **127.0.0.1 only** | n/a — nothing external can connect |
| 5432 | PostgreSQL | **unix socket only** | scram-sha-256, per-database roles |

Everything else — ntfy, Miniflux, changedetection, healthchecks — binds to
loopback and is reachable only through HAProxy.

## Syslog: local only

The collector listens on `127.0.0.1:6514`. Nothing outside the machine can send
it a log line. That is a stronger property than any authentication scheme,
because there is no credential to steal, leak, or guess.

**Why it is not open to the network.** rsyslog's TLS driver offers exactly four
authentication modes, and only two of them authenticate anything:

| Mode | What it accepts |
|---|---|
| `anon` | anyone who can reach the port |
| `x509/certvalid` | any certificate valid under the configured CA |
| `x509/name` | a valid certificate whose CN is on a permitted list |
| `x509/fingerprint` | one specific pinned certificate |

The trap is `x509/certvalid` pointed at a public CA. If the CA file is a Let's
Encrypt chain, then *any* certificate Let's Encrypt has ever issued — to anyone,
for any domain — is accepted. That is not a restriction, it is an open door with
a lock painted on it.

The syslog protocol has no password or token concept, so there is no
"TLS plus a shared secret" option at the transport layer. Real remote ingestion
requires issuing client certificates from a **private** CA you control, setting
`AuthMode="x509/name"` with an explicit peer list, and restricting the port at
the firewall as well. `vps/syslog/client-example.conf` documents that setup; it
is commented out because turning it on is a deliberate decision, not a default.

The firewall additionally carries an explicit `deny 6514/tcp` rule. That is
redundant while rsyslog binds loopback — which is the point. It means a future
edit to the rsyslog config cannot quietly publish the collector.

The certificate on the loopback listener is self-signed and generated at install
time. It is deliberately outside the certbot rotation: a public CA attests domain
control, which is meaningless for a socket on `127.0.0.1`.

## Brute-force protection

Four layers, each catching what the one above it lets through.

### 1. HAProxy, per request

Two stick tables track every client address.

**Sustained authentication failures.** `http_err_rate` counts 4xx responses over
five minutes. This is a much better signal than raw request rate: a brute-force
attempt looks like completely ordinary traffic apart from the failures. Above 30
in five minutes, the client's `gpc0` flag is set.

**A set flag is sticky.** Once flagged, the client is `silent-drop`ped — the
connection closes with no response at all — for the table's full hour, even if it
stops sending. Backing off does not clear the penalty, and a scanner learns
nothing from the silence while burning its own connection timeout.

**Login forms get their own budget.** POSTs to `/`, `/accounts/login` and
`/login` are tracked in a second table and capped at ten per five minutes per
address, independent of general traffic.

**Volumetric limits.** 400 requests per 10s or 200 new connections per 10s → 429.

**Unknown Host headers → 421.** Someone connecting to the raw IP and asking for
something that is not one of your four domains is a scanner, and is refused
before reaching any backend.

### 2. HTTP basic auth on the admin UIs

changedetection.io **ships with no authentication whatsoever**. Left as the spec
described it, its full admin interface would be open to anyone who found the
hostname — and that interface drives a real browser holding the logins you gave
it via Browser Steps. It is now gated behind basic auth in HAProxy, so a
brute-force attempt never reaches the application.

The healthchecks web UI is gated the same way, on top of its own Django login.
`/ping/` and `/api/` are exempt so the office PC can still check in; the ping
UUID is the credential there.

Credentials are in `ADMIN_UI_USER` / `ADMIN_UI_PASSWORD` in `hub.env`.

Miniflux and ntfy are *not* behind basic auth — mobile clients cannot easily do
two layers of authentication, and both have real authentication of their own.
They rely on the rate limiting above and the bans below.

### 3. fail2ban, at the firewall

HAProxy's blocks live in memory: they are lost on reload and expire after an
hour. fail2ban makes a repeat offender's ban durable and drops the packets before
they cost a TLS handshake.

| Jail | Watches | Trigger |
|---|---|---|
| `nh-haproxy-auth` | `/var/log/haproxy.log` | 15 × 401/403 in 10 min |
| `nh-haproxy-abuse` | `/var/log/haproxy.log` | 30 × 429/421 in 10 min |

Both escalate: each repeat offence multiplies the ban by four, up to a week.

There is intentionally no `sshd` jail here — if you already run one it is yours
to configure, and the installer reports whether one is active rather than
imposing its own.

Watching HAProxy rather than each application is deliberate — the log format is
one *we* define, so the regex cannot silently stop matching because an upstream
project reworded a message. One filter covers all four backends.

`85-fail2ban.sh` runs `fail2ban-regex` against known-good sample lines at install
time and **fails the install** if a filter does not match. A failregex that
matches nothing is worse than no jail: it looks like protection and provides
none.

> Put your own addresses in `FAIL2BAN_IGNOREIP` before you need to. A mistyped
> password from home should not lock you out of your own services.

### 4. ufw

**This project does not reshape your firewall.** `15-firewall.sh` adds allow
rules for 80 and 443 — the only ports this stack needs — and reports on
everything else. It never changes the default policy, never enables or disables
ufw, and never deletes a rule, because this host runs other services and
silently rewriting its firewall is a good way to break them.

The recommended hardening is printed rather than applied:

```bash
sudo /opt/notification-hub/bin/firewall.sh --dry-run   # see exactly what it would do
sudo /opt/notification-hub/bin/firewall.sh --harden    # apply it deliberately
```

`--harden` sets the default incoming policy to deny, rate-limits SSH, and adds
explicit denies for 6514 and 5432. Read each against your other services first —
in particular, default-deny will cut off anything that lacks an explicit allow
rule.

## Coexisting with what is already on the box

This stack is designed to be installed onto a VPS that already runs other
things, so every step that touches shared state is additive:

| Shared thing | How it is handled |
|---|---|
| **ufw** | Adds 80/443 only. Never changes defaults, never enables, never deletes. |
| **fail2ban** | Adds `nh-*` filters and jails only. **No `[DEFAULT]` section** — one there would rewrite the behaviour of every existing jail. **No `[sshd]` jail** — yours is reported, not replaced. Reloads rather than restarts, so current bans survive. |
| **HAProxy** | An existing config not written by this project is backed up to `haproxy.cfg.pre-notification-hub.<timestamp>` before being replaced, with a warning telling you to merge anything it routed into the template. |
| **Ports** | `05-preflight.sh` refuses to install if anything already holds a port the stack wants, naming the process. Every internal port is configurable in `hub.env`. |
| **HAProxy's log** | If the haproxy package already ships an rsyslog rule or logrotate entry for `/var/log/haproxy.log`, those are used as-is rather than a competing one being installed. |
| **:443** | Shared by SNI. Passthrough domains reach their own backends untouched; only this project's four domains are TLS-terminated. The routing table is untracked and lives on the host — see [tls-passthrough.md](tls-passthrough.md). |
| **:80** | Stays owned by HAProxy permanently — certbot renews on `ACME_HTTP_PORT` behind it, so renewals never stop the proxy and never interrupt other services. |

## Credential handling

- Every secret lives in `/etc/notification-hub/hub.env`, mode `0600`, root-owned,
  gitignored. Nothing is hardcoded.
- ntfy uses asymmetric accounts on purpose: `phone` is **read-only** on every
  topic, `publisher` is **write-only**. A token leaking from the office PC cannot
  be used to read back your mail; a lost phone cannot forge alerts. Each source
  has its own token so any one can be revoked alone.
- Each PostgreSQL service has its own role and database, with
  `REVOKE CONNECT ... FROM PUBLIC`, so one leaked credential does not reach the
  others.
- The backup archive is `age`-encrypted **before** upload. The private key is
  generated off the VPS and never stored on it — so losing the VPS does not lose
  the backups, and compromising the VPS does not expose them.
- The backup job refuses to run if any `*.pem` or `*.key` reaches its staging
  area. TLS private keys are re-issuable from ACME in minutes; shipping them to a
  chat app buys nothing but risk.

## Verifying it

```bash
# Only 22/80/443 open; syslog and postgres denied
sudo ufw status verbose

# The syslog listener is loopback-bound, and postgres has no TCP listener at all
ss -ltn | grep -E '6514|5432'

# Admin UIs demand credentials
curl -s -o /dev/null -w '%{http_code}\n' https://watch.example.com/     # 401
curl -s -o /dev/null -w '%{http_code}\n' https://checks.example.com/    # 401
curl -s -o /dev/null -w '%{http_code}\n' https://checks.example.com/ping/x  # not 401

# An unknown Host is refused
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: nope.invalid' https://<vps-ip>/ -k   # 421

# ntfy topics are not publicly readable
curl -s -o /dev/null -w '%{http_code}\n' https://ntfy.example.com/mail/json?poll=1      # 403

# Jails are loaded and matching
sudo fail2ban-client status
sudo fail2ban-client status nh-haproxy-auth
sudo fail2ban-regex /var/log/haproxy.log /etc/fail2ban/filter.d/nh-haproxy-auth.conf

# Trip the login limiter (expect 429 well before the 20th attempt)
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code} " -X POST -d 'username=x&password=y' \
    https://rss.example.com/
done; echo
```

After that last test your own address is likely flagged for an hour. Clear it:

```bash
sudo fail2ban-client set nh-haproxy-auth unbanip <your-ip>
echo "clear table st_clients" | sudo socat stdio /run/haproxy/admin.sock
```

## Known limitations

- **HAProxy's tables are per-process and in memory.** A reload clears them.
  fail2ban is the layer that persists, which is why both exist.
- **Rate limits are per source address.** A distributed attempt from many
  addresses is slowed, not stopped. The real protection for ntfy and Miniflux is
  that both require a credential at all times.
- **fail2ban bans are IPv4/IPv6 addresses.** An attacker with a large address
  pool can rotate. Basic auth on the admin UIs is what actually stops those.
- **Miniflux's Fever and Google Reader endpoints** are excluded from the strict
  login limiter, because RSS clients poll them frequently with credentials
  attached. They are still covered by the 4xx error-rate tracking.
