#!/usr/bin/env bash
# changedetection.io (+ its Playwright browser) and healthchecks.io.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars CD_DOMAIN HC_DOMAIN PG_HEALTHCHECKS_PASSWORD

command -v docker >/dev/null || die "docker not installed; run 10-packages.sh first"

HC_SECRET_KEY="$(set_env_var HC_SECRET_KEY "$(gen_secret 50)")"
export HC_SECRET_KEY

ensure_dir /var/lib/changedetection 0755 root:root
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

# Give healthchecks time to run its migrations against the shared database.
for _ in $(seq 1 30); do
  if curl -fsS -m 3 -o /dev/null http://127.0.0.1:8000/; then break; fi
  sleep 2
done

if ! curl -fsS -m 5 -o /dev/null http://127.0.0.1:8000/; then
  die "healthchecks is not answering — check: docker compose -f /etc/notification-hub/docker/docker-compose.yml logs healthchecks"
fi
if ! curl -fsS -m 5 -o /dev/null http://127.0.0.1:5000/; then
  die "changedetection is not answering — check: docker compose -f /etc/notification-hub/docker/docker-compose.yml logs changedetection"
fi

log "containers are up"
log "create the healthchecks superuser with:"
log "  docker compose -f /etc/notification-hub/docker/docker-compose.yml exec healthchecks ./manage.py createsuperuser"
log "then follow docs/healthchecks-setup.md to create one check per watcher"
