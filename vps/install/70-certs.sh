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

for script in distribute-certs.sh check-cert-renewal.sh apply-pending-restarts.sh; do
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
log "issue certificates with: certbot certonly --standalone -d <domain> --email $ACME_EMAIL --agree-tos"
log "then run: $HUB_PREFIX/bin/distribute-certs.sh"
