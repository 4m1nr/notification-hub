#!/usr/bin/env bash
# Report liveness of the VPS-side services to healthchecks.io.
#
# The point of a dead-man's-switch is that silence is the alert, so this only
# pings when the service it is vouching for is genuinely up. A timer that pings
# unconditionally monitors the timer, not the service.
set -uo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
if [[ -f "$HUB_ENV" ]]; then
  set -a; source "$HUB_ENV"; set +a
fi

ping_check() {
  local url="$1"
  [[ -n "$url" ]] || return 0
  curl -fsS -m 10 --retry 2 -o /dev/null "$url"
}

# The RSS relay is only healthy if the unit is running *and* it answers on its
# health endpoint — a wedged process still counts as "active" to systemd.
if [[ -n "${HC_PING_URL_RSS:-}" ]]; then
  if systemctl is-active --quiet rss-relay \
     && curl -fsS -m 5 -o /dev/null "http://${RSS_RELAY_LISTEN:-127.0.0.1:8181}/healthz"; then
    ping_check "$HC_PING_URL_RSS"
  else
    echo "rss-relay unhealthy; withholding ping" >&2
  fi
fi

# rsyslog owns the syslog-ntfy handler as a child process, so rsyslog being up is
# the correct liveness signal for the syslog path.
if [[ -n "${HC_PING_URL_SYSLOG:-}" ]]; then
  if systemctl is-active --quiet rsyslog; then
    ping_check "$HC_PING_URL_SYSLOG"
  else
    echo "rsyslog not active; withholding ping" >&2
  fi
fi

exit 0
