#!/usr/bin/env bash
# Central syslog collector over TLS, with severity-filtered alerting to ntfy.
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

if [[ ! -f /etc/certs/syslog/fullchain.pem ]]; then
  warn "no certificate in /etc/certs/syslog — the TLS listener will not start."
  warn "issue one for your syslog domain and run distribute-certs.sh, then re-run this script."
fi

install_file "$REPO_ROOT/vps/syslog/05-template.conf" /etc/rsyslog.d/05-notification-hub-template.conf || true
render "$REPO_ROOT/vps/syslog/10-remote-tls.conf.tmpl" /etc/rsyslog.d/10-notification-hub-remote-tls.conf || true
render "$REPO_ROOT/vps/syslog/50-ntfy-alert.conf.tmpl" /etc/rsyslog.d/50-notification-hub-alert.conf || true

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
systemctl is-active --quiet rsyslog || die "rsyslog failed to start"

log "syslog collector ready on TLS port ${SYSLOG_TLS_PORT}, alerting at severity <= ${SYSLOG_SEVERITY_MAX}"
log "client config example: $REPO_ROOT/vps/syslog/client-example.conf"
