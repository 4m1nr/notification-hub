#!/usr/bin/env bash
# Local syslog collector with severity-filtered alerting to ntfy.
#
# The listener is bound to 127.0.0.1. Only this machine can send to it, so there
# is no sender to authenticate and no credential to leak. See docs/security.md
# for what opening it up would require.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars NTFY_URL NTFY_TOKEN_SYSLOG

# 0 emerg .. 7 debug. 4 is "warning": alert on warning and worse, stay quiet for
# notice/info/debug, which is where routine log volume lives.
export SYSLOG_SEVERITY_MAX="${SYSLOG_SEVERITY_MAX:-4}"
export SYSLOG_TLS_PORT="${SYSLOG_TLS_PORT:-6514}"

apt_ensure rsyslog rsyslog-gnutls

go_build_install syslog-ntfy

# Self-signed certificate for the loopback listener. Deliberately not from
# Let's Encrypt: a public CA attests domain control, which means nothing for a
# socket on 127.0.0.1, and it would drag this into the certbot rotation for no
# benefit. Regenerated only when missing or expired.
ensure_dir /etc/certs/syslog 0750 root:syslog
if [[ ! -f /etc/certs/syslog/fullchain.pem ]] \
   || ! openssl x509 -in /etc/certs/syslog/fullchain.pem -noout -checkend 604800 >/dev/null 2>&1; then
  log "generating self-signed certificate for the loopback syslog listener"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -keyout /etc/certs/syslog/privkey.pem \
    -out /etc/certs/syslog/fullchain.pem \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
  # rsyslog wants a CA file even in anon mode; its own certificate serves.
  cp /etc/certs/syslog/fullchain.pem /etc/certs/syslog/ca.pem
fi
chmod 0640 /etc/certs/syslog/privkey.pem
chmod 0644 /etc/certs/syslog/fullchain.pem /etc/certs/syslog/ca.pem
chown -R root:syslog /etc/certs/syslog

install_file "$REPO_ROOT/vps/syslog/05-template.conf" /etc/rsyslog.d/05-notification-hub-template.conf || true
render "$REPO_ROOT/vps/syslog/10-local-tls.conf.tmpl" /etc/rsyslog.d/10-notification-hub-local-tls.conf || true
install_file "$REPO_ROOT/vps/syslog/20-haproxy-log.conf" /etc/rsyslog.d/20-notification-hub-haproxy.conf || true
render "$REPO_ROOT/vps/syslog/50-ntfy-alert.conf.tmpl" /etc/rsyslog.d/50-notification-hub-alert.conf || true

# Remove the old remote-listener drop-in if this box was installed before the
# collector became loopback-only.
if [[ -f /etc/rsyslog.d/10-notification-hub-remote-tls.conf ]]; then
  warn "removing the previous remote syslog listener config"
  rm -f /etc/rsyslog.d/10-notification-hub-remote-tls.conf
fi

# rsyslog runs the omprog handler as a child process, so the handler inherits
# rsyslog's environment — which is where its ntfy credentials come from.
ensure_dir /etc/systemd/system/rsyslog.service.d 0755 root:root
cat > /etc/systemd/system/rsyslog.service.d/notification-hub.conf <<EOF
[Service]
EnvironmentFile=$HUB_ENV
EOF
SYSTEMD_DIRTY=1
systemd_reload

rsyslogd -N1 -f /etc/rsyslog.conf >/dev/null 2>&1 || die "rsyslog configuration is invalid"

systemctl restart rsyslog
sleep 1
systemctl is-active --quiet rsyslog || die "rsyslog failed to start"

# Prove the listener is not reachable from the network.
if ss -ltn 2>/dev/null | grep -qE "0\.0\.0\.0:${SYSLOG_TLS_PORT}|\[::\]:${SYSLOG_TLS_PORT}"; then
  die "the syslog listener is bound to all interfaces — expected 127.0.0.1 only"
fi
log "syslog collector listening on 127.0.0.1:${SYSLOG_TLS_PORT} (not reachable from the network)"
log "alerting at severity <= ${SYSLOG_SEVERITY_MAX}"
