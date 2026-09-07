# Managing feeds from Android

Miniflux is the one service here that is deliberately exposed to the public
internet, because subscriptions are managed from the phone rather than from a
desktop. That exposure is the reason for the hardening below.

Web UI: `https://rss.example.com/` — log in with `MINIFLUX_ADMIN_USERNAME` /
`MINIFLUX_ADMIN_PASSWORD` from `/etc/notification-hub/hub.env`.

## Picking an Android client

Three protocols, three levels of fidelity:

### Readrops — native Miniflux API (recommended)

Speaks Miniflux's own API, so it gets everything: categories, starred entries,
per-feed settings, original article fetching.

- Account type: **Miniflux**
- URL: `https://rss.example.com`
- Username / password: your Miniflux login

### News+, FeedMe — Fever API

The Fever API is a compatibility layer. It works well, but it flattens some
Miniflux concepts and has no notion of categories the way the native API does.

It needs a **separate password**, which is not your login password:

1. Miniflux → **Settings → Integrations → Fever**
2. Tick **Activate Fever API**, set a Fever password, save.
3. In the app:
   - Endpoint: `https://rss.example.com/fever/`
   - Username: your Miniflux username
   - Password: the **Fever** password you just set

### EasyRSS, FocusReader — Google Reader API

Also a compatibility layer, with its own separate password:

1. Miniflux → **Settings → Integrations → Google Reader**
2. Tick **Activate Google Reader API**, set a password, save.
3. Endpoint: `https://rss.example.com/` (the app appends the API path itself)

## How new entries reach your phone

You do **not** need the Android app running for notifications. Miniflux polls
feeds on the server, and on new entries it calls the webhook:

```
Miniflux (polls every 60s)
   └─ webhook POST → 127.0.0.1:8181/webhook  (rss-relay)
        └─ one ntfy message per entry → topic `rss`
```

The relay listens on loopback only and is not exposed through HAProxy — Miniflux
runs on the same host, so there is nothing to expose.

Each delivery is signed with HMAC-SHA256 in `X-Miniflux-Signature`, using
`MINIFLUX_WEBHOOK_SECRET`. That signature is the *only* authentication on the
endpoint, and the relay rejects anything that does not verify with `401`.

Verify the wiring in Miniflux under **Settings → Integrations → Webhook**:
the URL should be `http://127.0.0.1:8181/webhook` and the secret should match.

## Why this instance is safe to expose

A public login form on a VPS gets found by scanners within hours. What protects it:

- **Rate limiting in HAProxy** — a per-IP stick table caps requests to `/`,
  `/fever/` and `/googlereader/` at 30 per 30 seconds, then returns `429`.
- **`HTTPS=1`** in `miniflux.conf` — session cookies get `Secure` and `SameSite`.
  Without this the login silently fails to stick behind a TLS-terminating proxy.
- **No self-registration** — Miniflux has none by default, and one admin account
  is created by the installer. Do not add a registration path.
- **A generated 32-character admin password**, not one you reused.

Optionally, add a fail2ban filter on Miniflux's journald output:

```bash
sudo journalctl -u miniflux | grep -i "authentication failure"
```

It is off by default because HAProxy's rate limit already blunts credential
stuffing, and fail2ban on a public IP has its own false-positive cost.
