# Books: Calibre-Web-Automated + Shelfmark

Two containers, one shared folder:

```
             fetch.example.com                         books.example.com
   you ──▶ Shelfmark ──search──▶ Anna's Archive        CWA ◀── browser, OPDS, Kobo
               │         (+ Libgen / Z-Lib mirrors)      ▲
               └── download ──▶ /var/lib/books/ingest ───┘ import, convert, delete
               └── Apprise ──▶ ntfy `books`
```

- **Calibre-Web-Automated (CWA)** holds the library at `/var/lib/books/library`:
  a normal Calibre library (`metadata.db` + one folder per author). It watches
  `/var/lib/books/ingest`, and anything that lands there is imported (converted
  if needed) and then **deleted** from the ingest folder.
- **Shelfmark** searches Anna's Archive and its mirrors and downloads into that
  ingest folder. It never touches the library directly.

Both run as the unprivileged `books` system user and publish only on loopback.
HAProxy terminates TLS for both. Why they keep SQLite rather than using the
shared PostgreSQL: [architecture.md](architecture.md#one-database-three-tenants).

Anna's Archive and its mirrors host material whose legal status depends on
where you are and what you download. That is your call to make; this stack only
automates the fetching.

---

## First login

### CWA — `https://books.example.com/`

It ships with **`admin` / `admin123`**, and it is *not* behind the proxy's basic
auth (e-readers could not get past a second login). Change it first:
**Admin → Users → admin → Password**.

Then, under **Admin → CWA Settings**, check:

| Setting | Suggested | Why |
|---|---|---|
| Auto-convert | on, target EPUB | Kobo and most readers want EPUB; PDFs are left as PDF unless you opt in |
| Keep originals in `processed_books` | your choice | keeps the pre-conversion file under `/var/lib/books/cwa-config/processed_books` — costs disk |
| Auto-fetch metadata | on | fills in covers and descriptions for downloads with thin metadata |

Create a separate non-admin user for daily reading and for e-readers, so the
admin password never sits on a device.

### Shelfmark — `https://fetch.example.com/`

The browser asks for the admin UI basic auth (`ADMIN_UI_USER` /
`ADMIN_UI_PASSWORD` in `hub.env`). That is the only login: HAProxy passes the
verified user to Shelfmark in `X-Auth-User` and Shelfmark (`AUTH_METHOD=proxy`)
trusts it.

Search, pick a result, download. Within a minute or so it should appear in CWA.

## Anna's Archive mirrors

Without a membership ("donator") key, downloads go through Anna's Archive's slow
download pages, which sit behind Cloudflare. Shelfmark's standard image ships a
Chromium to get past that. That browser is the memory peak, so the container is
capped at `SHELFMARK_MEM_LIMIT` (default 1g, plus as much again in swap). Slow downloads also queue, so a big batch takes a while.

Anna's Archive changes domains often. Shelfmark tries `AA_MIRROR_URLS` in order
and fails over. When downloads start failing for every book, fix the list
first:

```bash
sudo "${EDITOR:-vi}" /etc/notification-hub/hub.env      # AA_MIRROR_URLS=https://...,https://...
cd /etc/notification-hub/docker && sudo docker compose up -d shelfmark
```

If you get a membership later, add `AA_DONATOR_KEY` to the shelfmark
`environment` in `vps/docker/docker-compose.yml` (pointing at a hub.env
variable, like the others) and re-run `90-docker-apps.sh`.

## Notifications

CWA sends none. Shelfmark can report finished and failed downloads through
Apprise. In Shelfmark's settings, add this notification URL:

```
ntfys://<NTFY_TOKEN_BOOKS>@ntfy.example.com/books
```

`NTFY_TOKEN_BOOKS` is in `hub.env` (created by `30-ntfy.sh`). As with
changedetection: `ntfys` with the *s*, and the token in the user position, not
as a password. Then subscribe the phone to the `books` topic
([ntfy-topics.md](ntfy-topics.md)).

## Reading on devices

| Client | Point it at | Credentials |
|---|---|---|
| KOReader, Moon+ Reader, Librera, Thorium (OPDS) | `https://books.example.com/opds` | your CWA user |
| Kobo | **Profile → Kobo Sync** in CWA gives a per-user API URL; put it in the Kobo's `.kobo/Kobo/Kobo eReader.conf` as `api_endpoint=` | the token in the URL |
| Send-to-Kindle / e-mail | needs SMTP, which this stack does not configure | — |

Enable Kobo sync first under **Admin → Basic Configuration → Feature
Configuration → Enable Kobo sync**.

## Adding books by hand

Drop files into the ingest folder; CWA picks them up:

```bash
sudo install -o books -g books -m 0640 ~/some-book.epub /var/lib/books/ingest/
```

Or use **Upload** in CWA's web UI. HAProxy gives CWA a 5-minute server timeout
for this, because the upload only answers once the import has finished.

## Importing an existing Calibre library

```bash
cd /etc/notification-hub/docker
sudo docker compose stop cwa
# The library folder must contain metadata.db at its top level.
sudo rsync -a /path/to/Calibre\ Library/ /var/lib/books/library/
sudo chown -R books:books /var/lib/books/library
sudo docker compose start cwa
```

CWA uses the library as-is. If you are coming from plain Calibre-Web, also copy
its `app.db` into `/var/lib/books/cwa-config/` *before* the first start to keep
users and shelves. CWA migrates it.

## Backups

The daily backup includes `metadata.db`, CWA's `app.db`, and Shelfmark's
settings, all taken live with `sqlite3 .backup`. It does **not** include the
book files themselves: a library outgrows a daily Telegram upload in 45 MB parts
fast. Copy them somewhere yourself, for example:

```bash
rsync -a --delete /var/lib/books/library/ backup-host:books/
```

Restore: [backup-restore.md](backup-restore.md) step 4.

## Troubleshooting

```bash
cd /etc/notification-hub/docker
sudo docker compose logs --tail 100 cwa
sudo docker compose logs --tail 100 shelfmark
ls -l /var/lib/books/ingest/      # files stuck here = CWA is not importing
```

- **Shelfmark downloads but nothing appears in CWA.** Check the ingest folder.
  If files sit there, check ownership (`books:books`) and the CWA log.
- **Every download fails.** It is almost always the mirror list (above). Also
  check `docker stats shelfmark` — if it sits at its limit, the bypass browser
  is being OOM-killed. Raise `SHELFMARK_MEM_LIMIT` in `hub.env` (or add swap) and
  re-run `90-docker-apps.sh`.
- **A big PDF upload or conversion fails.** Same check for `cwa` against
  `CWA_MEM_LIMIT`; `docker inspect cwa --format '{{.State.OOMKilled}}'` says
  whether it was killed for memory.
- **CWA logs you out repeatedly.** `TRUSTED_PROXY_COUNT` must be `1`, and if the
  domain is proxied through Cloudflare, HAProxy already rewrites the client
  address, so it stays `1`.
