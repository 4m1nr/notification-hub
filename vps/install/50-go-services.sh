#!/usr/bin/env bash
# Build and install the VPS-side Go services.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars NTFY_URL NTFY_TOKEN_RSS MINIFLUX_WEBHOOK_SECRET

ensure_sysuser nhub "$HUB_STATE"
ensure_dir "$HUB_STATE" 0750 nhub:nhub

go_build_install rss-relay
go_build_install syslog-ntfy

install_file "$REPO_ROOT/vps/heartbeat/hc-heartbeat.sh" \
  "$HUB_PREFIX/bin/hc-heartbeat.sh" 0755 root:root || true

install_unit "$REPO_ROOT/vps/systemd/rss-relay.service"
install_unit "$REPO_ROOT/vps/systemd/hc-heartbeat.service"
install_unit "$REPO_ROOT/vps/systemd/hc-heartbeat.timer"
systemd_reload

enable_now rss-relay.service
enable_now hc-heartbeat.timer

# The relay must answer before Miniflux starts delivering to it.
sleep 1
if curl -fsS -m 5 -o /dev/null "http://${RSS_RELAY_LISTEN:-127.0.0.1:8181}/healthz"; then
  log "rss-relay is healthy"
else
  die "rss-relay is not answering on /healthz — check: journalctl -u rss-relay -n 50"
fi
