# TLS passthrough for other services on the same host

This VPS can serve other things on `:443` alongside the notification hub. HAProxy
splits the port by TLS SNI: a passthrough domain's handshake is forwarded
untouched, so that service keeps terminating its own TLS and never knows a proxy
is in front of it.

```
:443 (and each port= port, for the entries naming it)
     ──▶ inspect SNI ──┬── exact name in passthrough.conf ──▶ its target, handshake untouched
                       │     (or decrypted here, for 'terminate' and redirect hosts)
                       ├── one of the hub's 4 domains ──▶ TLS terminated here
                       ├── matches a '*.x.y' in passthrough.conf ──▶ the wildcard's target
                       └── anything else, or no SNI ──▶ silent-drop
    (plain HTTP on a port= port ──▶ its redirect, or https on the same port)
```

## The routing table is not in git

`/etc/haproxy/passthrough.conf` lives only on the VPS. Your hostnames and
internal ports are yours, and this repository is public, so they are deliberately
kept out of it. The repo ships only `passthrough.conf.example` with placeholder
domains.

Two files are **generated** from that table and must not be edited directly:

| File | Contents |
|---|---|
| `/etc/haproxy/sni-passthrough.map` | SNI hostname or `*.x.y` wildcard → backend name |
| `/etc/haproxy/conf.d/10-passthrough.cfg` | the backend definitions (and the decrypting frontend, if any domain uses `terminate`) |
| `/etc/haproxy/cloudflare-only.passthrough.lst` | table entries (names or wildcards) only Cloudflare may connect to |
| `/etc/haproxy/redirect-hosts.lst` | hosts in the redirect table (`/etc/haproxy/redirects.conf`), for port 80 |

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

## Wildcards and exceptions

A line whose domain is `*.example.com` routes every name **one label** under
`example.com` — `a.example.com`, `b.example.com` — to one target. A line for a
specific name under it is an **exception**: that name goes to its own target,
with its own options, whatever the wildcard says.

```bash
# Quote the wildcard, or the shell may expand the '*'.
sudo /opt/notification-hub/bin/passthrough.sh add '*.example.com' 127.0.0.1:8443
sudo /opt/notification-hub/bin/passthrough.sh add z.example.com  127.0.0.1:9443   # exception
```

| SNI | Goes to |
|---|---|
| `a.example.com`, `anything.example.com` | `*.example.com` → `127.0.0.1:8443` |
| `z.example.com` | its own line → `127.0.0.1:9443` |
| `example.com` | **not** matched — add it as its own line if you need it |
| `a.b.example.com` | **not** matched — add `a.b.example.com` or `'*.b.example.com'` |
| a hub domain under `example.com` (e.g. `ntfy.example.com`) | still the hub — wildcards never capture the hub's domains |

The precedence is fixed, not order-dependent: an exact name always beats a
wildcard, wherever the lines sit in the file. Because a wildcard covers exactly
one label, no two wildcards can ever match the same name, so there is nothing
else to rank.

Options follow the line that matched. If `*.example.com` is `cloudflare-only`
and `z.example.com` is not, direct connections to `z.example.com` are allowed
and everything else under the wildcard still has to come through Cloudflare —
and the reverse works too. With `terminate`, the `Host` header is resolved the
same way after decryption.

A `*` anywhere other than as the whole first label (`a.*.example.com`,
`*foo.example.com`) is rejected by `add` and `sync`.

**Certificates.** Plain passthrough still needs none here: each backend presents
its own, so the service behind `*.example.com` should hold a wildcard
certificate (or one per name it serves). A `terminate` wildcard needs a
wildcard certificate *here* — `issue-cert.sh '*.example.com'` with
`domains.map` format `combined` or `both`, service `haproxy`; see
[certificates.md](certificates.md). `sync` warns if none covers it.

## HTTP redirects

Send a whole host, or everything under a path on it, somewhere else. The rest
of the path and the query string are kept:

```bash
sudo /opt/notification-hub/bin/passthrough.sh redirect add x.example.com/sub https://a.example.net/sub
```

| Request | Redirected to |
|---|---|
| `https://x.example.com/sub/page?id=7` | `https://a.example.net/sub/page?id=7` |
| `https://x.example.com/sub` | `https://a.example.net/sub` |
| `https://x.example.com/subway` | not matched (`/sub` matches whole path segments only) |
| `http://x.example.com/sub/page` | straight to `https://a.example.net/sub/page` — no detour through HTTPS on `x.example.com` |

The destination path can differ (`x.example.com/old https://a.example.net/new`
sends `/old/p` to `/new/p`). Leave the path off to redirect a whole host
(`old.example.com https://new.example.com`). When prefixes on one host
overlap, the longest wins, wherever the lines sit in the table.

Options, after the destination:

| Option | Effect |
|---|---|
| `301` `302` `303` `307` `308` | status code; default **302** (temporary). Browsers cache 301/308 indefinitely, so only use them once the target is final. 307/308 keep the method and body of a POST. |
| `drop-path` | always send to the destination exactly, ignoring the rest of the path and the query |
| `port=N[,N...]` | answer on these HTTPS ports instead of 443 (and its HTTP side, 80); see *Listening on other ports* |

```bash
sudo /opt/notification-hub/bin/passthrough.sh redirect add old.example.com https://new.example.com 308
sudo /opt/notification-hub/bin/passthrough.sh redirect add x.example.com/promo https://shop.example.net/landing drop-path
sudo /opt/notification-hub/bin/passthrough.sh redirect list
sudo /opt/notification-hub/bin/passthrough.sh redirect remove x.example.com/sub
```

The table is `/etc/haproxy/redirects.conf` (not in git), one redirect per line:
`source  destination  [options]`. After editing it by hand, run
`passthrough.sh sync`.

**What you need to do for a redirect host:**

1. **DNS** for the source host must point at this VPS (or be proxied through
   Cloudflare to it).
2. **A certificate here.** A path is only visible after TLS is decrypted, so
   HAProxy answers the HTTPS request itself. Add the host to `domains.map`
   (format `combined`, service `haproxy`) and run `issue-cert.sh <host>`, or
   cover it with a wildcard. `sync` warns while none covers it; until then
   browsers get a certificate error before they ever see the redirect.
   Plain-HTTP redirects work without one.

**How it combines with the passthrough table.** This is decided port by port.
A redirect's ports are 443 unless it has `port=`, and so are a line's.

| On a port where the source host is… | Result |
|---|---|
| in no table | it exists only for its redirects; other paths get **404** |
| a `terminate` line, or under a `terminate` wildcard | redirected paths redirect, every other path still reaches its target |
| a plain passthrough line | **rejected** — its TLS is never decrypted on that port, so no path can be seen. Give the redirect another port, or add `terminate` to the line |
| under a plain passthrough wildcard | becomes an exception to it there: redirected paths redirect, other paths get 404 (`sync` says so) |
| one of the hub's own domains | **rejected** |

On the ports a line or wildcard listens on but the redirect does not, nothing
changes. So a plain passthrough host can keep its handshake untouched on 443
and still have redirects on another port:

```bash
# servenet.example.com stays plain passthrough on 443; port 8000 decrypts it
# for this redirect, and answers 404 for other paths.
sudo /opt/notification-hub/bin/passthrough.sh redirect add servenet.example.com/sub https://other.example.net/sub port=8000
```

Sources are letters, digits and `. _ ~ - /`; wildcards are not supported as a
redirect source. A destination under its own source (`x.example.com` →
`https://x.example.com/new`) is rejected, since it would redirect forever.
`add` checks all of this before it touches the running proxy, and puts the
table back as it was if anything is rejected.

## Listening on other ports

Every entry listens on 443 unless it says otherwise. `port=` replaces that with
one or more ports of your choosing, for passthrough lines and redirects alike:

```bash
sudo /opt/notification-hub/bin/passthrough.sh add app.example.com 127.0.0.1:9000 port=8443
sudo /opt/notification-hub/bin/passthrough.sh add both.example.com 127.0.0.1:9001 port=443,8443
sudo /opt/notification-hub/bin/passthrough.sh redirect add go.example.com/x https://a.example.net/x port=9443
```

On a port other than 443, HAProxy opens a listener of its own that:

| Arrives on that port | Result |
|---|---|
| TLS whose SNI is an entry naming the port | routed exactly as on 443: passthrough, `terminate` or redirects |
| plain HTTP for such a host | `301` to `https://<host>:<port>/<same path>`, or, for a redirect host, straight to the redirect's destination |
| any other SNI or Host, no SNI, or neither TLS nor HTTP | **silently dropped**; the client waits until it times out |

An entry with `port=8443` is no longer served on 443 at all. List both
(`port=443,8443`) to keep it on 443. Port 443 always comes with plain HTTP on
80. Port 80 cannot be listed itself, and neither can `ACME_HTTP_PORT`.

Names resolve the same way on every port: the exact line first, then the
wildcard. So an exception keeps its own ports too. With `*.example.com port=8443`
and `z.example.com` (default 443), `z.example.com` is served on 443 only and is
dropped on 8443; it never falls back to the wildcard.

A redirect may use any port except one where its host is plain passthrough
(see *How it combines with the passthrough table* above). On ports its host's
line does not listen on, the host is decrypted only for the redirects there,
and other paths get 404.

**What you need to do for a new port:**

1. **Open it in the firewall.** `sync` warns when ufw is active and does not
   allow the port yet. It never changes the firewall itself:
   `sudo ufw allow 8443/tcp comment 'notification-hub haproxy'`. Do the same in
   any cloud-provider firewall in front of the VPS.
2. **Nothing else may use the port.** `sync` refuses one that another process
   holds, since HAProxy could not bind it.
3. **Behind Cloudflare,** only Cloudflare's proxied ports work through the
   orange cloud: HTTPS 443, 2053, 2083, 2087, 2096, 8443, and HTTP 80, 8080,
   8880, 2052, 2082, 2086, 2095. Any other port needs a grey-cloud (DNS-only)
   record, and then `cloudflare-only` would drop every client.
4. **Certificates** are unchanged: a `terminate` or redirect host needs one here
   whatever port it is on, and passthrough hosts present their own.

`list` and `redirect list` show each entry's `port=`.

## Editing the table by hand

```bash
sudo "${EDITOR:-vi}" /etc/haproxy/passthrough.conf
sudo /opt/notification-hub/bin/passthrough.sh sync
```

The format is one line per domain:

```
# domain                     target            options
app.example.com              127.0.0.1:8443
other.example.com            127.0.0.1:9000    proxy-protocol cloudflare-only
```

The domain may be a `*.x.y` wildcard (see above). Options, any number,
space-separated: `port=N[,N...]` (above), `proxy-protocol` / `proxy-protocol-v1`
(below), `cloudflare-only` and `terminate` (both under *Behind Cloudflare*).

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
terminates — which includes passthrough domains with the `terminate` option.

If the backend's own certificate comes from certbot on this host, issue it with
`issue-cert.sh <domain>`, never `certbot certonly --standalone`: HAProxy owns
`:80` and forwards challenges to `ACME_HTTP_PORT`, and a bare certbot call
that tries to bind `:80` fails with *Could not bind TCP port 80*. Wildcard and
multi-name certificates are covered in `docs/certificates.md`; a wildcard here
also satisfies `terminate` domains under it.

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

## Behind Cloudflare: the `terminate` option

With the record proxied (orange cloud), the connection HAProxy receives is
Cloudflare's, not the client's. The client's address is in the
`CF-Connecting-IP` request header — inside the TLS stream, which passthrough by
design never decrypts. So `proxy-protocol` alone sends the backend a
Cloudflare edge address, and there is no way around that without reading the
request.

`terminate` reads it. That domain's TLS is decrypted by HAProxy, the source is
rewritten from `CF-Connecting-IP` exactly as for the hub's own domains (trusted
only when the peer is in Cloudflare's ranges, deleted otherwise), and the
request is re-encrypted to the backend with the original name as SNI. With
`proxy-protocol` as well, the PROXY header now carries the **real client**:

```bash
sudo /opt/notification-hub/bin/passthrough.sh add cdn.example.com 127.0.0.1:443 \
  terminate proxy-protocol cloudflare-only
```

```
client ─▶ Cloudflare ─▶ :443 tls_in ─▶ pt_https_in (decrypt, set-src from CF-Connecting-IP)
                                          └─▶ backend over TLS, PROXY v2 = real client
```

What it needs and changes:

- **A certificate here.** Add the domain to `domains.map` (`combined` or
  `both`, service `haproxy`) and run `issue-cert.sh <domain>`. `sync` warns if
  no certificate covers it; until then clients get another domain's.
- **HTTP only** — HTTP/1.1, h2, WebSocket and gRPC. Cloudflare only proxies
  HTTP anyway, so any orange-clouded record qualifies; a raw TLS protocol on a
  grey-clouded record must stay plain passthrough.
- **The backend is unchanged.** It still receives TLS (HAProxy does not check
  its certificate, since it is this host's own service), and with
  `proxy-protocol` it must accept PROXY protocol as described above.
  WebSockets are kept on HTTP/1.1 towards it; other traffic may use h2.
- It also gets `X-Forwarded-For` and `X-Forwarded-Proto`, for backends that
  prefer headers to PROXY protocol.
- Direct (non-Cloudflare) clients still work unless `cloudflare-only` is set;
  their PROXY header carries their own address.

### `cloudflare-only`

Drops, silently, any connection for this SNI whose TCP peer is not in
`/etc/haproxy/cloudflare-ips.lst`, so the origin cannot be used to bypass
Cloudflare. Works with or without `terminate`. With `terminate`, the `Host`
header is checked too, after decryption. For the hub's own domains the
equivalent is `CLOUDFLARE_ONLY_DOMAINS` in `hub.env`; see *Cloudflare-only
domains* in [security.md](security.md).

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
