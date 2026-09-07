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

## The backend sees HAProxy's IP, not the client's

This surprises everyone once. A service that correctly logs client addresses when
reached directly will log `127.0.0.1` for everything once it is behind the proxy.

**Why.** In TCP mode HAProxy is not forwarding packets — it accepts the client's
connection and opens a **second, independent** TCP connection to the backend. The
kernel stamps that new connection with HAProxy's own source address, because
HAProxy is genuinely the one making it. The client's address exists only in
HAProxy's memory. When the client connects directly, the service's
`getpeername()` returns the real address because there is only one connection.

In HTTP mode you would solve this by injecting an `X-Forwarded-For` header. That
is not available here: with TLS passthrough HAProxy never decrypts the stream, so
there is no header to add — the payload is opaque bytes it must not touch.

**The fix is PROXY protocol.** HAProxy prepends a small header to the TCP stream,
*before* the TLS handshake, carrying the original source and destination
address and port. Both ends have to agree it is there.

```bash
sudo /opt/notification-hub/bin/passthrough.sh add node.example.com 127.0.0.1:442 proxy-protocol
```

That emits `send-proxy-v2` on the backend's server line. Use
`proxy-protocol-v1` for backends that only speak the older text format.

> **Once enabled, the backend requires it.** A backend configured to accept PROXY
> protocol will reject any connection that arrives without the header — so
> connecting to that port directly, bypassing HAProxy, stops working. That is
> expected, and it is also a useful property: the backend can no longer be
> reached except through the proxy.

### Configuring the backend

The backend must be told to expect the header. For **Xray-core** (which is what
PasarGuard node and similar projects run), it goes in the inbound's
`streamSettings`, under the block for whichever transport that inbound uses:

```jsonc
// network: "tcp"
"streamSettings": {
  "network": "tcp",
  "tcpSettings": { "acceptProxyProtocol": true }
}

// network: "ws"
"streamSettings": {
  "network": "ws",
  "wsSettings": { "acceptProxyProtocol": true, "path": "/..." }
}

// network: "httpupgrade"
"streamSettings": {
  "network": "httpupgrade",
  "httpupgradeSettings": { "acceptProxyProtocol": true, "path": "/..." }
}
```

Set it on the **inbound only**, and on the transport that inbound actually uses —
putting it in `tcpSettings` when the inbound is WebSocket does nothing. Xray
accepts both v1 and v2, so either option above works.

Other common backends: nginx `listen ... proxy_protocol` plus
`set_real_ip_from`/`real_ip_header proxy_protocol`; Caddy needs a plugin;
sing-box uses `"proxy_protocol": true` on the inbound.

### Checking it worked

```bash
# The generated backend should carry send-proxy-v2
grep -A3 "$(sudo /opt/notification-hub/bin/passthrough.sh list 2>&1 | awk '/proxy-protocol/{print $1}' | head -1)" \
  /etc/haproxy/conf.d/10-passthrough.cfg

# Watch the backend's own logs while making a request from a known address.
# Before: every connection shows 127.0.0.1. After: your real address.
```

If connections start failing outright after enabling it, the backend is not
actually accepting PROXY protocol — it is reading the header as if it were the
first bytes of a TLS handshake, and closing. Re-check that the setting is on the
right transport block for that inbound.

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
