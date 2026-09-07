#!/usr/bin/env bash
# Apply certificate changes that distribute-certs.sh queued.
#
# Renewals happen whenever they happen; restarts happen here, once a day, at a
# time chosen by us. That is the entire point of the split: no surprise restarts
# at 3am because a certificate came up for renewal.
set -euo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
HUB_STATE="${HUB_STATE:-/var/lib/notification-hub}"
PENDING_DIR="$HUB_STATE/pending-restart"

[[ -f "$HUB_ENV" ]] && { set -a; source "$HUB_ENV"; set +a; }

log() { printf '[apply-pending-restarts] %s\n' "$*" >&2; }

if [[ ! -d "$PENDING_DIR" ]] || [[ -z "$(ls -A "$PENDING_DIR" 2>/dev/null)" ]]; then
  log "nothing pending"
  exit 0
fi

# apply runs the correct action for a service and reports success.
apply() {
  case "$1" in
    haproxy)
      # reload, never restart: HAProxy hands listening sockets to the new
      # process, so in-flight connections — including the phone's long-lived
      # ntfy stream — survive.
      log "reloading haproxy"
      haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null || {
        log "haproxy config is invalid; refusing to reload"
        return 1
      }
      systemctl reload haproxy
      ;;
    rsyslog)
      log "restarting rsyslog"
      systemctl restart rsyslog
      ;;
    tunnel)
      unit="${TUNNEL_SERVICE_UNIT:-}"
      if [[ -z "$unit" ]]; then
        log "TUNNEL_SERVICE_UNIT is not set in $HUB_ENV; skipping tunnel restart"
        return 1
      fi
      log "restarting $unit"
      systemctl restart "$unit"
      ;;
    *)
      log "unknown service '$1' — leaving its flag in place for inspection"
      return 1
      ;;
  esac
}

failed=0
for flag in "$PENDING_DIR"/*; do
  [[ -e "$flag" ]] || continue
  service="$(basename "$flag")"
  queued_at="$(cat "$flag" 2>/dev/null || echo unknown)"
  log "pending: $service (queued $queued_at)"

  if apply "$service"; then
    # Only clear the flag once the action actually succeeded, so a failure is
    # retried tomorrow instead of being silently forgotten.
    rm -f "$flag"
    log "$service: applied"
  else
    failed=1
    log "$service: FAILED — flag kept for the next run"
  fi
done

exit "$failed"
