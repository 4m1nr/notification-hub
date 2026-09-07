# Watching pages behind a login

changedetection.io's plain HTTP fetcher cannot get past a login form — it has no
session, no JavaScript, and no way to click anything. Getting behind a login gate
requires the **Playwright** fetcher, which drives a real Chromium.

That is why this stack runs `sockpuppetbrowser` alongside changedetection, wired
up with `PLAYWRIGHT_DRIVER_URL=ws://sockpuppet:3000`. With that in place, the
**Browser Steps** feature becomes available; without it, the Browser Steps tab is
inert.

> **The browser container has no published ports, deliberately.** Anything that
> can reach it can drive a browser holding your saved sessions and make it fetch
> arbitrary URLs. It is reachable only from the changedetection container on the
> internal compose network. Do not add a `ports:` entry to it.

## Setting up a watch behind a login

1. Open `https://watch.example.com/` and click **Add a new change detection
   watch**. Enter the URL of the page you actually want to monitor — not the
   login page.

2. Open the watch's **Edit** screen and set **Fetch method** to
   *Playwright/Chrome*. Do this before anything else; the Browser Steps tab only
   works for a Playwright watch.

3. Go to the **Browser Steps** tab. You get a live screenshot of the page as the
   browser sees it — which, on first load, will be the login form. Build the
   sequence:

   | Step | Operation | What to fill in |
   |---|---|---|
   | 1 | `Goto site` | (no value — loads the watch URL) |
   | 2 | `Enter text in field` | Selector for the username input, value = your username |
   | 3 | `Enter text in field` | Selector for the password input, value = your password |
   | 4 | `Click element` | Selector for the submit button |
   | 5 | `Wait for seconds` | `3` — let the redirect and page render finish |

   Click the screenshot to pick a selector rather than typing one by hand; the UI
   fills in a working CSS selector for the element you clicked.

4. Click **Apply**, then **Preview**. The preview must show the *post-login* page.
   If it still shows the login form, the sequence failed — the usual causes are a
   too-short wait, a submit button that is not a real `<button>`, or a site that
   requires a cookie banner to be dismissed first (add another `Click element`
   step for it).

5. Only now set the **CSS selector** on the *Filters & Triggers* tab, to scope the
   watch to the element you care about — a price, a status line, a table row —
   rather than the whole page. Watching a whole page means every navbar timestamp
   and rotating advert counts as a change.

   ```
   #order-status .current-state
   .price-box span.amount
   table.results tbody tr:first-child
   ```

6. Set a **Recheck time** appropriate to the page. Browser Steps re-run on
   *every* check, so each one is a full browser session, a real login, and a few
   seconds of CPU. Five minutes is reasonable; thirty seconds is not.

## Credentials

Put them in the individual watch's Browser Steps, not in a global setting. Each
watch then carries only the credentials it needs, and deleting the watch deletes
them.

They are stored in changedetection's datastore under `/var/lib/changedetection`,
which is included in the daily backup — and that backup is age-encrypted before
it leaves the VPS, which is one of the reasons the encryption is not optional.

## Notifications

Set the notification URL on the watch (or globally under **Settings →
Notifications**):

```
ntfy://:<NTFY_TOKEN_SITECHANGES>@ntfy.example.com/site-changes
```

Note the empty username before the colon — that is Apprise's syntax for
token-based ntfy auth rather than username/password.

Useful notification body, which gives you the diff on the lock screen:

```
Title:  {{watch_title}}
Body:   {{diff}}
```

## Troubleshooting

```bash
cd /etc/notification-hub/docker

# Is the browser reachable from changedetection?
sudo docker compose logs sockpuppet --tail 50
sudo docker compose logs changedetection --tail 50

# Both should be running
sudo docker compose ps
```

- **"Fetch failed" on every Playwright watch** — sockpuppet is not running, or
  `PLAYWRIGHT_DRIVER_URL` does not match its service name.
- **Browser Steps tab does nothing** — the watch is still on the plain HTTP
  fetcher. Change **Fetch method** first.
- **Chromium crashes immediately** — the `SYS_ADMIN` capability is missing from
  the sockpuppet service.
- **Login works in preview but not on scheduled checks** — the site is
  rate-limiting repeated logins. Increase the recheck interval.
