#!/usr/bin/env bash
# fail2ban: the durable layer under HAProxy's in-memory rate limiting.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env

export FAIL2BAN_IGNOREIP="${FAIL2BAN_IGNOREIP:-}"

apt_ensure fail2ban

for f in "$REPO_ROOT"/vps/security/fail2ban/filter.d/*.conf; do
  install_file "$f" "/etc/fail2ban/filter.d/$(basename "$f")" 0644 root:root || true
done
render "$REPO_ROOT/vps/security/fail2ban/jail.d/notification-hub.conf" \
  /etc/fail2ban/jail.d/notification-hub.conf 0644 root:root || true

# HAProxy's log must exist before fail2ban starts, or the jail refuses to load.
if [[ ! -f /var/log/haproxy.log ]]; then
  install -o root -g adm -m 0640 /dev/null /var/log/haproxy.log
fi

# rsyslog writes it, so it needs its own rotation — the haproxy package's
# logrotate entry does not cover a file we create ourselves.
cat > /etc/logrotate.d/notification-hub-haproxy <<'EOF'
/var/log/haproxy.log {
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

# ---------------------------------------------------------------------------
# Verify the filters actually match before trusting them.
#
# A failregex that silently matches nothing is worse than no jail at all: it
# looks like protection and provides none. These sample lines are in the exact
# format rsyslog writes, so a mismatch here is a real bug.
# ---------------------------------------------------------------------------
verify_filter() {
  local filter="$1" expected="$2"
  local found
  found="$(fail2ban-regex "$REPO_ROOT/vps/security/fail2ban/testlines.log" \
             "/etc/fail2ban/filter.d/${filter}.conf" 2>/dev/null \
           | grep -oP 'Lines:.*?\K\d+(?= matched)' | head -n1)"
  found="${found:-0}"
  if [[ "$found" != "$expected" ]]; then
    fail2ban-regex "$REPO_ROOT/vps/security/fail2ban/testlines.log" \
      "/etc/fail2ban/filter.d/${filter}.conf" 2>&1 | tail -20 >&2
    die "filter $filter matched $found of the $expected expected sample lines — it would not ban anything"
  fi
  log "filter $filter matches its $expected sample lines"
}

verify_filter nh-haproxy-auth  2
verify_filter nh-haproxy-abuse 2

systemctl enable fail2ban >/dev/null
systemctl restart fail2ban
sleep 2
systemctl is-active --quiet fail2ban || die "fail2ban failed to start — check: journalctl -u fail2ban -n 50"

log "active jails:"
fail2ban-client status 2>/dev/null | sed 's/^/    /' >&2

if [[ -z "${FAIL2BAN_IGNOREIP:-}" ]]; then
  warn "FAIL2BAN_IGNOREIP is empty — consider adding your home/office addresses"
  warn "to $HUB_ENV so a mistyped password cannot lock you out of your own services"
fi
