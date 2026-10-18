#!/usr/bin/env bash
# changedetection.io (+ its Playwright browser), healthchecks.io, and the books
# pair: Calibre-Web-Automated and Shelfmark.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars CD_DOMAIN HC_DOMAIN CD_PORT HC_PORT PG_PORT PG_HEALTHCHECKS_PASSWORD \
  BOOKS_DOMAIN SHELFMARK_DOMAIN

command -v docker >/dev/null || die "docker not installed; run 10-packages.sh first"

HC_SECRET_KEY="$(set_env_var HC_SECRET_KEY "$(gen_secret 50)")"
export HC_SECRET_KEY

ensure_dir /var/lib/changedetection 0755 root:root

# Books: one unprivileged account owns the library, so both containers (which
# drop to PUID/PGID) can write the shared ingest folder and nothing else on the
# host can. A hub upgraded from before books existed has none of these settings
# yet, so the defaults are appended here rather than demanded.
CWA_PORT="$(set_env_var CWA_PORT 8083)"
SHELFMARK_PORT="$(set_env_var SHELFMARK_PORT 8084)"
BOOK_LANGUAGE="$(set_env_var BOOK_LANGUAGE en)"
# .env.example ships BOOKS_TZ empty, which set_env_var would keep as-is.
if [[ -z "${BOOKS_TZ:-}" ]]; then
  BOOKS_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  put_env_var BOOKS_TZ "${BOOKS_TZ:-Etc/UTC}"
  BOOKS_TZ="${BOOKS_TZ:-Etc/UTC}"
fi
AA_MIRROR_URLS="$(set_env_var AA_MIRROR_URLS "https://annas-archive.gl,https://annas-archive.org,https://annas-archive.se,https://annas-archive.li")"
export CWA_PORT SHELFMARK_PORT BOOK_LANGUAGE BOOKS_TZ AA_MIRROR_URLS

ensure_sysuser books
put_env_var BOOKS_UID "$(id -u books)"
put_env_var BOOKS_GID "$(id -g books)"
ensure_dir /var/lib/books 0750 books:books
for d in library ingest cwa-config shelfmark-config; do
  ensure_dir "/var/lib/books/$d" 0750 books:books
done
ensure_dir /etc/notification-hub/docker 0750 root:root

install_file "$REPO_ROOT/vps/docker/docker-compose.yml" \
  /etc/notification-hub/docker/docker-compose.yml 0640 root:root || true

# Compose reads ${VAR} from an .env file beside the compose file. Point it at the
# hub environment rather than duplicating credentials.
ln -sf "$HUB_ENV" /etc/notification-hub/docker/.env

cd /etc/notification-hub/docker

log "pulling images"
docker compose pull --quiet

log "starting containers"
docker compose up -d

# Django only answers requests whose Host is in ALLOWED_HOSTS (= HC_DOMAIN), so
# probing the loopback port needs the public hostname in the header.
hc_up() { curl -fs -m "${1:-3}" -o /dev/null -H "Host: ${HC_DOMAIN}" "http://127.0.0.1:${HC_PORT}/"; }
cd_up() { curl -fs -m "${1:-3}" -o /dev/null "http://127.0.0.1:${CD_PORT}/"; }
# Any HTTP answer counts: CWA redirects to its login page, and Shelfmark refuses
# a request with no X-Auth-User, which is exactly what it should do here.
cwa_up() { curl -s -m "${1:-3}" -o /dev/null "http://127.0.0.1:${CWA_PORT}/"; }
sm_up()  { curl -s -m "${1:-3}" -o /dev/null "http://127.0.0.1:${SHELFMARK_PORT}/"; }

# Give healthchecks time to run its migrations against the shared database.
for _ in $(seq 1 30); do
  if hc_up; then break; fi
  sleep 2
done

hc_up 5 || die "healthchecks is not answering on 127.0.0.1:${HC_PORT} — check: docker compose -f /etc/notification-hub/docker/docker-compose.yml logs healthchecks"
cd_up 5 || die "changedetection is not answering on 127.0.0.1:${CD_PORT} — check: docker compose -f /etc/notification-hub/docker/docker-compose.yml logs changedetection"

# CWA runs its first-start setup (Calibre library, app.db) before it listens.
for _ in $(seq 1 60); do
  if cwa_up && sm_up; then break; fi
  sleep 2
done
cwa_up 5 || die "cwa is not answering on 127.0.0.1:${CWA_PORT} — check: docker compose -f /etc/notification-hub/docker/docker-compose.yml logs cwa"
sm_up 5 || die "shelfmark is not answering on 127.0.0.1:${SHELFMARK_PORT} — check: docker compose -f /etc/notification-hub/docker/docker-compose.yml logs shelfmark"

log "containers are up"
log "create the healthchecks superuser with:"
log "  docker compose -f /etc/notification-hub/docker/docker-compose.yml exec healthchecks ./manage.py createsuperuser"
log "then follow docs/healthchecks-setup.md to create one check per watcher"
log ""
log "books: https://${BOOKS_DOMAIN}/ ships with the login admin / admin123 —"
log "  change it now, before anything else (Admin -> Edit user)"
log "  https://${SHELFMARK_DOMAIN}/ uses the admin UI basic auth (ADMIN_UI_* in $HUB_ENV)"
log "  then follow docs/books.md"
