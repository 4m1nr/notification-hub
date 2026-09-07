# TLS passthrough for other services on the same host

This VPS can serve other things on `:443` alongside the notification hub. HAProxy
splits the port by TLS SNI: a passthrough domain's handshake is forwarded
untouched, so that service keeps terminating its own TLS and never knows a proxy
is in front of it.

```
:443 ──▶ inspect SNI ──┬── in passthrough.conf ──▶ its target, handshake untouched
                       ├── one of the hub's 4 domains ──▶ TLS terminated here
                       └── anything else, or no SNI ──▶ silent-drop
```

## The routing table is not in git

`/etc/haproxy/passthrough.conf` lives only on the VPS. Your hostnames and
internal ports are yours, and this repository is public, so they are deliberately
kept out of it. The repo ships only `passthrough.conf.example` with placeholder
domains.

Two files are **generated** from that table and must not be edited directly:

| File | Contents |
|---|---|
| `/etc/haproxy/sni-passthrough.map` | SNI hostname → backend name |
| `/etc/haproxy/conf.d/10-passthrough.cfg` | the backend definitions |

`haproxy.cfg` itself contains only a generic map lookup, so **adding a domain
never means editing a tracked file** — and a `git pull` can never clobber your
routing.

## Adding a domain

```bash
sudo /opt/notification-hub/bin/passthrough.sh add app.example.com 127.0.0.1:8443
```

That appends to the table, regenerates both files, validates the whole
configuration, and reloads HAProxy — a reload, not a restart, so existing
connections (including other passthrough sessions) are handed to the new process
rather than dropped.

```bash
sudo /opt/notification-hub/bin/passthrough.sh list
sudo /opt/notification-hub/bin/passthrough.sh remove app.example.com
```

`list` flags any target with nothing listening behind it — otherwise that domain
fails in a way that looks like a proxy fault rather than a missing service.

## Editing the table by hand

```bash
sudo "${EDITOR:-vi}" /etc/haproxy/passthrough.conf
sudo /opt/notification-hub/bin/passthrough.sh sync
```

The format is one line per domain:

```
# domain                     target
app.example.com              127.0.0.1:8443
other.example.com            127.0.0.1:9000
```

`sync` is idempotent, and refuses to reload if the resulting configuration does
not validate — so a typo leaves the running proxy untouched rather than taking
every service on the host down.

## How it is loaded

HAProxy has no `include` directive, but it accepts repeated `-f`, and a directory
argument loads every file inside it. `80-haproxy.sh` installs a systemd drop-in
that appends `-f /etc/haproxy/conf.d` to the unit's `EXTRAOPTS`, *appending* to
whatever the distribution already sets rather than replacing it, so a future
package update that adds an option there is not silently dropped.

Both generated files must exist even when empty — HAProxy refuses to start if the
map named in its config is missing. The installer creates them.

## Certificates

Passthrough domains need **no certificate here**. Their handshake is never
decrypted, so the backend service presents its own. Do not add them to
`/etc/notification-hub/domains.map`; that table is only for domains this proxy
terminates.

## Things worth knowing

- **Long timeouts are deliberate.** The TCP frontend uses `timeout client 1h` and
  each generated backend `timeout server 1h`. The `defaults` section is HTTP-mode
  with 60s timeouts, which would cut a passthrough session mid-stream.
- **Clients without SNI are dropped.** They cannot be routed, since SNI is the
  only thing distinguishing destinations on a shared port. This includes anyone
  connecting to the bare IP.
- **A domain in the table that resolves elsewhere does nothing.** Routing happens
  only for traffic that actually reaches this host.
- **Renewals never interrupt passthrough.** certbot binds `ACME_HTTP_PORT` behind
  HAProxy rather than taking `:80`, so the proxy stays up throughout.
