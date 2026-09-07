#!/usr/bin/env bash
# Miniflux — RSS subscription management, exposed publicly so it can be driven
# from an Android reader.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars MINIFLUX_DOMAIN PG_MINIFLUX_PASSWORD

MINIFLUX_VERSION="${MINIFLUX_VERSION:-2.2.15}"

if ! command -v miniflux >/dev/null; then
  arch="$(dpkg --print-architecture)"
  deb="/tmp/miniflux_${MINIFLUX_VERSION}_${arch}.deb"
  log "downloading miniflux ${MINIFLUX_VERSION}"
  curl -fsSL -o "$deb" \
    "https://github.com/miniflux/v2/releases/download/${MINIFLUX_VERSION}/miniflux_${MINIFLUX_VERSION}_${arch}.deb"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"
  rm -f "$deb"
fi

# The webhook secret is shared with the relay; generate it once and keep it.
MINIFLUX_WEBHOOK_SECRET="$(set_env_var MINIFLUX_WEBHOOK_SECRET "$(gen_secret 40)")"
export MINIFLUX_WEBHOOK_SECRET

usermod -aG postgres miniflux 2>/dev/null || true

render "$REPO_ROOT/vps/miniflux/miniflux.conf.tmpl" /etc/miniflux.conf 0640 root:miniflux || true

log "running database migrations"
miniflux -config-file /etc/miniflux.conf -migrate

# Create the single admin account on first run only.
ADMIN_USER="${MINIFLUX_ADMIN_USERNAME:-$(set_env_var MINIFLUX_ADMIN_USERNAME admin)}"
ADMIN_PASS="$(set_env_var MINIFLUX_ADMIN_PASSWORD "$(gen_secret 32)")"
if ! miniflux -config-file /etc/miniflux.conf -info >/dev/null 2>&1 \
   || ! su - postgres -c "psql -tAX -d miniflux -c \"SELECT 1 FROM users WHERE username='${ADMIN_USER}'\"" | grep -q 1; then
  log "creating miniflux admin user '$ADMIN_USER'"
  ADMIN_USERNAME="$ADMIN_USER" ADMIN_PASSWORD="$ADMIN_PASS" \
    miniflux -config-file /etc/miniflux.conf -create-admin || \
    warn "admin creation skipped (it may already exist)"
fi

systemctl enable miniflux >/dev/null
systemctl restart miniflux
sleep 2
systemctl is-active --quiet miniflux || die "miniflux failed to start — check: journalctl -u miniflux -n 50"

log "miniflux ready at https://${MINIFLUX_DOMAIN}/ (admin: $ADMIN_USER)"
log "next: enable the Fever API under Settings -> Integrations for Android readers"
