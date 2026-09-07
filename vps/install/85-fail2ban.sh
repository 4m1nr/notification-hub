#!/usr/bin/env bash
# fail2ban: the durable layer under HAProxy's in-memory rate limiting.
#
# This box may already run fail2ban for unrelated services, so this script is
# strictly additive:
#   * it writes only nh-* filters and one jail.d file containing only nh-* jails
#   * it defines no [DEFAULT] section, which would alter every existing jail
#   * it defines no [sshd] jail; an existing one is reported, never overwritten
#   * it reloads rather than restarts, so bans already in effect survive
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env

export FAIL2BAN_IGNOREIP="${FAIL2BAN_IGNOREIP:-}"
export HAPROXY_LOG="${HAPROXY_LOG:-/var/log/haproxy.log}"

apt_ensure fail2ban

PREEXISTING=0
if systemctl is-active --quiet fail2ban; then
  PREEXISTING=1
  log "fail2ban is already running — adding jails alongside the existing ones"
  fail2ban-client status 2>/dev/null | sed 's/^/    existing: /' >&2 || true
fi

for f in "$REPO_ROOT"/vps/security/fail2ban/filter.d/*.conf; do
  install_file "$f" "/etc/fail2ban/filter.d/$(basename "$f")" 0644 root:root || true
done
render "$REPO_ROOT/vps/security/fail2ban/jail.d/notification-hub.conf" \
  /etc/fail2ban/jail.d/notification-hub.conf 0644 root:root || true

# Refuse to ship a [DEFAULT] section, even by accident — it would silently
# reconfigure every other jail on this host.
if grep -qE '^\s*\[DEFAULT\]' /etc/fail2ban/jail.d/notification-hub.conf; then
  die "our jail file contains a [DEFAULT] section; that would override other jails"
fi

# ---------------------------------------------------------------------------
# HAProxy's log has to exist and be written before the jails can watch it.
# The haproxy package may already ship an rsyslog rule for this; if so, use it
# rather than installing a competing one.
# ---------------------------------------------------------------------------
if [[ ! -f "$HAPROXY_LOG" ]]; then
  install -o root -g adm -m 0640 /dev/null "$HAPROXY_LOG"
fi

if ls /etc/logrotate.d/haproxy >/dev/null 2>&1 && grep -q "$HAPROXY_LOG" /etc/logrotate.d/haproxy 2>/dev/null; then
  log "logrotate for $HAPROXY_LOG already provided by the haproxy package — leaving it alone"
  rm -f /etc/logrotate.d/notification-hub-haproxy
else
  cat > /etc/logrotate.d/notification-hub-haproxy <<EOF
$HAPROXY_LOG {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    su root adm
    create 0640 root adm
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || systemctl kill -s HUP rsyslog.service
    endscript
}
EOF
  log "installed logrotate for $HAPROXY_LOG"
fi

# ---------------------------------------------------------------------------
# Verify the filters actually match before trusting them.
#
# A failregex that silently matches nothing is worse than no jail at all: it
# looks like protection and provides none.
# ---------------------------------------------------------------------------
verify_filter() {
  local filter="$1" expected="$2" found
  found="$(fail2ban-regex "$REPO_ROOT/vps/security/fail2ban/testlines.log" \
             "/etc/fail2ban/filter.d/${filter}.conf" 2>/dev/null \
           | grep -oP 'Lines:.*?\K\d+(?= matched)' | head -n1)"
  found="${found:-0}"
  if [[ "$found" != "$expected" ]]; then
    fail2ban-regex "$REPO_ROOT/vps/security/fail2ban/testlines.log" \
      "/etc/fail2ban/filter.d/${filter}.conf" 2>&1 | tail -20 >&2
    die "filter $filter matched $found of $expected sample lines — it would ban nothing"
  fi
  log "filter $filter matches its $expected sample lines"
}
verify_filter nh-haproxy-auth  2
verify_filter nh-haproxy-abuse 2

# Reload keeps existing bans and other jails running; restart would drop them.
systemctl enable fail2ban >/dev/null
if (( PREEXISTING )); then
  log "reloading fail2ban (preserving current bans)"
  fail2ban-client reload >/dev/null || die "fail2ban reload failed — check: journalctl -u fail2ban -n 50"
else
  systemctl restart fail2ban
  sleep 2
fi
systemctl is-active --quiet fail2ban || die "fail2ban is not running — check: journalctl -u fail2ban -n 50"

for jail in nh-haproxy-auth nh-haproxy-abuse; do
  fail2ban-client status "$jail" >/dev/null 2>&1 \
    && log "jail $jail is active" \
    || die "jail $jail did not load — check: journalctl -u fail2ban -n 50"
done

log "all jails on this host:"
fail2ban-client status 2>/dev/null | sed 's/^/    /' >&2

if fail2ban-client status sshd >/dev/null 2>&1; then
  log "an sshd jail is already active — left untouched, as it is not ours to manage"
else
  warn "no sshd jail is active. This project does not add one, to avoid clashing"
  warn "with your own policy, but SSH is exposed and worth protecting."
fi

if [[ -z "${FAIL2BAN_IGNOREIP:-}" ]]; then
  warn "FAIL2BAN_IGNOREIP is empty — add your home/office addresses to $HUB_ENV"
  warn "so a mistyped password cannot lock you out of your own services"
fi
