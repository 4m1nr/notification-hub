#!/usr/bin/env bash
# Certificate issuance, distribution and the decoupled restart schedule.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars ACME_EMAIL

CERT_RESTART_TIME="${CERT_RESTART_TIME:-04:30:00}"
export CERT_RESTART_TIME

apt_ensure certbot

ensure_dir /etc/certs 0755 root:root
ensure_dir /etc/certs/proxy 0750 root:root
ensure_dir /etc/certs/proxy/combined 0750 root:haproxy
ensure_dir /etc/certs/syslog 0750 root:syslog
ensure_dir /etc/certs/tunnel 0750 root:root
ensure_dir "$HUB_STATE/pending-restart" 0750 root:root

# The domain table lives outside the repo so it can be edited on the box without
# a git checkout; seed it from the repo on first install only.
if [[ ! -f /etc/notification-hub/domains.map ]]; then
  install_file "$REPO_ROOT/vps/certs/domains.map" /etc/notification-hub/domains.map 0640 root:root
  warn "edit /etc/notification-hub/domains.map and uncomment your domains before continuing"
fi

for script in distribute-certs.sh check-cert-renewal.sh apply-pending-restarts.sh issue-cert.sh; do
  install_file "$REPO_ROOT/vps/certs/$script" "$HUB_PREFIX/bin/$script" 0750 root:root || true
done

# Wire the distribution script in as a certbot deploy hook. Anything certbot
# renews — by any path — lands in the right places automatically.
ensure_dir /etc/letsencrypt/renewal-hooks/deploy 0755 root:root
cat > /etc/letsencrypt/renewal-hooks/deploy/10-notification-hub.sh <<'HOOK'
#!/usr/bin/env bash
exec /opt/notification-hub/bin/distribute-certs.sh
HOOK
chmod 0750 /etc/letsencrypt/renewal-hooks/deploy/10-notification-hub.sh

# Keep certbot off :80 by default. HAProxy owns :80 and forwards the challenge
# to ACME_HTTP_PORT, so any certbot run on this box — a manual `certbot renew`,
# a `certbot certonly --standalone` for a new domain — must listen there, or it
# fails with "Could not bind TCP port 80". Only this key is managed; anything
# else in cli.ini is left alone.
ACME_HTTP_PORT="${ACME_HTTP_PORT:-8402}"
CLI_INI=/etc/letsencrypt/cli.ini
touch "$CLI_INI"
if grep -qE '^http-01-port *=' "$CLI_INI"; then
  sed -i -E "s/^http-01-port *=.*/http-01-port = ${ACME_HTTP_PORT}/" "$CLI_INI"
else
  printf '\n# notification-hub: HAProxy owns :80 and forwards ACME challenges here\nhttp-01-port = %s\n' \
    "$ACME_HTTP_PORT" >> "$CLI_INI"
fi

# Lineages issued before this existed may have recorded :80 for renewal.
"$HUB_PREFIX/bin/issue-cert.sh" --pin-renewal-port

install_unit "$REPO_ROOT/vps/systemd/cert-renew-check.service"
install_unit "$REPO_ROOT/vps/systemd/cert-renew-check.timer"
install_unit "$REPO_ROOT/vps/systemd/cert-restart.service"
install_unit "$REPO_ROOT/vps/systemd/cert-restart.timer.tmpl"
systemd_reload

# The stock certbot timer renews at 30 days out on its own schedule. Leaving it
# enabled alongside ours means two things racing to renew the same lineages.
if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
  log "disabling stock certbot.timer in favour of cert-renew-check.timer"
  systemctl disable --now certbot.timer >/dev/null 2>&1 || true
fi

enable_now cert-renew-check.timer
enable_now cert-restart.timer

log "certificate automation installed"
log "issue certificates with: $HUB_PREFIX/bin/issue-cert.sh <domain>"
log "  (it binds :80 itself before HAProxy exists, and $ACME_HTTP_PORT behind it after)"
