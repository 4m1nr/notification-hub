# Adding books to a hub that is already running

For a VPS that already runs notification-hub and was installed before
Calibre-Web-Automated and Shelfmark existed here. A fresh install gets them
from [deploy.md](deploy.md) and does not need this page.

Every step is a re-run of an idempotent installer, so nothing already running
is reinstalled: existing passwords and ntfy tokens are reused, unchanged
containers are not recreated, and HAProxy is reloaded, not restarted. Budget
about 20 minutes, most of it waiting for image pulls.

---

## 0. Before you start

```bash
# A known-good backup from the current version
sudo /opt/notification-hub/bin/backup.sh --dry-run

# Memory and disk
free -h
df -h /var/lib
```

### Memory

Look at the **available** column of `free -h`, not *total*. The upgrade adds two
containers, capped at 768 MB (CWA) and 1 GB (Shelfmark), though both sit well
under that when idle. It also takes the hub's own footprint *down*: healthchecks
drops from four workers to one (about 200 MB less), changedetection and its
browser do one check at a time, Miniflux fetches with two workers, and PostgreSQL
gets a smaller buffer pool. Every container is capped, so a spike stays in that
container instead of making the kernel kill something else.

If *available* is under about 1.5 GB, and above all if *Swap* shows `0B`, add
swap first. On a small VPS it is the difference between a slow moment and the
kernel killing a random process:

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
# Only swap under real pressure, not as soon as the page cache grows
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf && sudo sysctl -p /etc/sysctl.d/99-swap.conf
```

Other things that help on a shared box:

- **Tools you only open now and then** (pgadmin, for example) can be stopped
  between uses: `docker stop pgadmin`, then `docker start pgadmin` when needed.
- **Run Shelfmark on demand.** CWA does not need it running.
  `cd /etc/notification-hub/docker && sudo docker compose stop shelfmark`,
  then `start` when you want to fetch something.
- **Caps** default in `docker-compose.yml` and can be overridden in `hub.env`.
  If a container keeps getting killed, raise its cap there and re-run
  `90-docker-apps.sh`. `docker stats` shows each container's usage against its
  limit.

  | Variable | Default | Container |
  |---|---|---|
  | `HC_MEM_LIMIT` | 256m | healthchecks |
  | `CD_MEM_LIMIT` | 256m | changedetection |
  | `BROWSER_MEM_LIMIT` | 768m | sockpuppet (changedetection's Chromium) |
  | `CWA_MEM_LIMIT` | 768m | Calibre-Web-Automated |
  | `SHELFMARK_MEM_LIMIT` | 1g | Shelfmark (it can also use as much again in swap) |

- **The PostgreSQL change** (`shared_buffers = 64MB`, `max_connections = 40`, in
  the cluster's `conf.d/notification-hub.conf`) restarts PostgreSQL once when you
  re-run `20-postgres.sh`. ntfy, Miniflux and healthchecks reconnect on their own.
  It is skipped when the cluster also holds databases that are not the hub's.

Pick two names (the defaults below are just examples), and create DNS records
for them pointing at the VPS. Proxied through Cloudflare is fine.

```bash
for d in books.example.com fetch.example.com; do
  printf '%-24s %s\n' "$d" "$(dig +short "$d" | tail -1)"
done
```

## 1. Pull the code

```bash
cd ~/notification-hub          # wherever you cloned it
git pull
```

## 2. Add the new settings

```bash
sudo "${EDITOR:-vi}" /etc/notification-hub/hub.env
```

Add these. Only the two domains are required. The rest are filled in with
defaults in step 7 if you leave them out:

```bash
BOOKS_DOMAIN=books.example.com
SHELFMARK_DOMAIN=fetch.example.com

# optional
AA_MIRROR_URLS=https://annas-archive.gl,https://annas-archive.org,https://annas-archive.se,https://annas-archive.li
BOOK_LANGUAGE=en
BOOKS_TZ=Europe/Berlin
CWA_PORT=8083
SHELFMARK_PORT=8084
```

If you use `CLOUDFLARE_ONLY_DOMAINS`, add the new names to it if they are
proxied.

## 3. Preflight and packages

(If you want the PostgreSQL memory change, add `20-postgres.sh` to this run. It
restarts PostgreSQL once, see [Memory](#memory).)


```bash
sudo ./bootstrap.sh 05-preflight.sh 10-packages.sh
```

Preflight now also checks `8083`/`8084`, and warns when available memory is low
or there is no swap, listing the largest processes. If a port is
taken, change `CWA_PORT`/`SHELFMARK_PORT` and re-run. `10-packages.sh` adds
`sqlite3`, which the backup needs for the book databases.

## 4. The `books` ntfy topic

```bash
sudo ./bootstrap.sh 30-ntfy.sh
sudo grep '^NTFY_TOKEN_BOOKS=' /etc/notification-hub/hub.env
```

This adds the `books` topic to both ntfy accounts and creates
`NTFY_TOKEN_BOOKS`. Existing tokens and passwords are kept. On the phone, add
a subscription to `books` ([ntfy-topics.md](ntfy-topics.md)).

> ntfy is restarted by this step, so the phone reconnects once.

## 5. Certificates

Skip this if a wildcard certificate already covers both names.

```bash
sudo "${EDITOR:-vi}" /etc/notification-hub/domains.map
#   books.example.com   /etc/certs/proxy/books   root:haproxy   both   haproxy
#   fetch.example.com   /etc/certs/proxy/fetch   root:haproxy   both   haproxy

sudo /opt/notification-hub/bin/issue-cert.sh books.example.com
sudo /opt/notification-hub/bin/issue-cert.sh fetch.example.com
```

HAProxy is running, so certbot answers the challenge behind it on
`ACME_HTTP_PORT`. Nothing is interrupted.

## 6. HAProxy

```bash
sudo ./bootstrap.sh 80-haproxy.sh
```

The new config is validated before it replaces the live one, and then HAProxy
is reloaded. Passthrough tunnels and ntfy subscriptions are not dropped.

The new names answer now, but with 503 until step 7 starts the containers.

## 7. Start the containers

```bash
sudo ./bootstrap.sh 90-docker-apps.sh
```

This creates the `books` system user, `/var/lib/books/{library,ingest,cwa-config,shelfmark-config}`,
pulls the two new images and starts them. It writes any book settings you left
out to `hub.env`. changedetection and healthchecks are not recreated unless
their image changed upstream (the same as any re-run).

## 8. Backups

```bash
sudo ./bootstrap.sh 95-backup.sh                       # installs the new backup.sh
sudo /opt/notification-hub/bin/backup.sh --dry-run
age -d -i backup-key.txt /var/backups/notification-hub/*-backup-$(date +%F).tar.gz.age \
  | tar tzf - | grep '^./books/'                       # on a machine with your key
```

`books/` should list `metadata.db` and `app.db` once CWA has started at least
once.

## 9. First login

1. `https://books.example.com/`: log in as **`admin` / `admin123`** and
   **change the password immediately**. CWA is reachable without the proxy's
   basic auth.
2. `https://fetch.example.com/`: the browser asks for `ADMIN_UI_USER` /
   `ADMIN_UI_PASSWORD` from `hub.env`.
3. In Shelfmark's settings, add the notification URL
   `ntfys://<NTFY_TOKEN_BOOKS>@<NTFY_DOMAIN>/books`.
4. Download one book. It should appear in CWA within a minute or two, and on
   the phone under `books`.

Bringing an existing Calibre library: [books.md](books.md#importing-an-existing-calibre-library).

## 10. Check

```bash
# Shelfmark refuses without the admin credential...
curl -s -o /dev/null -w '%{http_code}\n' https://fetch.example.com/                 # 401
# ...and a forged identity header changes nothing
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Auth-User: admin' https://fetch.example.com/   # 401
# CWA answers with its own login, not the proxy's realm
curl -sI https://books.example.com/ | grep -iE '^(HTTP|location|www-authenticate)'   # 302 to /login, no realm
# Everything that was there before still is
systemctl is-active haproxy ntfy miniflux rss-relay
cd /etc/notification-hub/docker && sudo docker compose ps
```

## Rolling back

The book data is never deleted by any of this.

```bash
cd /etc/notification-hub/docker && sudo docker compose stop cwa shelfmark
cd ~/notification-hub
git checkout <the commit you were on before>   # `git reflog` shows it
sudo ./bootstrap.sh 80-haproxy.sh 90-docker-apps.sh 95-backup.sh
```

The old HAProxy template does not know the new names, so they drop to 421.
The older compose file no longer lists `cwa` and `shelfmark`, so compose warns
about orphan containers. Remove just those two with `sudo docker rm cwa
shelfmark`. `/var/lib/books` and the new `hub.env` lines can stay. They are
harmless, and they make it easy to go forward again.
