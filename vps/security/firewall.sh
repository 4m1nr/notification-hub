#!/usr/bin/env bash
# Firewall rules this stack needs, added to whatever policy already exists.
#
# ─────────────────────────────────────────────────────────────────────────────
# This script is deliberately conservative, because this box runs other things.
#
# It will:      add allow rules for 80/tcp and 443/tcp if they are missing
# It will NOT:  change the default policy, enable or disable ufw, delete any
#               rule, or touch anything it did not add
#
# The hardening it does not apply on its own — default-deny inbound, SSH rate
# limiting, explicit denies for loopback-only services — is printed as a
# recommendation. Pass --harden to apply it deliberately, after reading what it
# would do to the rest of your setup.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
[[ -f "$HUB_ENV" ]] && { set -a; source "$HUB_ENV"; set +a; }

SSH_PORT="${SSH_PORT:-22}"
SYSLOG_PORT="${SYSLOG_TLS_PORT:-6514}"

HARDEN=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --harden)  HARDEN=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "usage: $0 [--harden] [--dry-run]" >&2; exit 1 ;;
  esac
done

log()  { printf '[firewall] %s\n' "$*" >&2; }
warn() { printf '[firewall] WARNING: %s\n' "$*" >&2; }
die()  { printf '[firewall] ERROR: %s\n' "$*" >&2; exit 1; }

command -v ufw >/dev/null || die "ufw not installed"

run() {
  if (( DRY_RUN )); then
    log "would run: ufw $*"
  else
    ufw "$@" >/dev/null
  fi
}

# has_rule matches an existing allow rule for a port, so re-runs add nothing.
has_rule() {
  ufw status 2>/dev/null | grep -qE "^${1}(/tcp)?[[:space:]]+ALLOW"
}

ACTIVE=1
ufw status 2>/dev/null | head -1 | grep -q inactive && ACTIVE=0

log "current state: $( ((ACTIVE)) && echo active || echo INACTIVE )"
if (( ACTIVE )); then
  ufw status verbose 2>/dev/null | sed 's/^/    /' >&2
fi

#--- What this stack actually needs -------------------------------------------
for port in 80 443; do
  if has_rule "$port"; then
    log "${port}/tcp already allowed"
  else
    log "allowing ${port}/tcp (required by haproxy)"
    run allow "${port}/tcp" comment 'notification-hub haproxy'
  fi
done

#--- Recommendations, applied only with --harden ------------------------------
DEFAULT_INCOMING="$(ufw status verbose 2>/dev/null | grep -oP 'Default:\s+\K\w+' | head -1)"

if (( HARDEN )); then
  log "--harden given: applying the recommended policy"
  [[ "$DEFAULT_INCOMING" == "deny" ]] || {
    warn "changing the default incoming policy to deny"
    warn "anything without an explicit allow rule will stop being reachable"
    run default deny incoming
  }
  run limit "${SSH_PORT}/tcp"
  run deny "${SYSLOG_PORT}/tcp" comment 'syslog is loopback-only'
  run deny 5432/tcp comment 'postgres is socket-only'
else
  log ""
  log "not applied (run with --harden to apply, after checking each against your"
  log "other services):"
  [[ "$DEFAULT_INCOMING" == "deny" ]] \
    && log "  · default incoming policy is already 'deny' — good" \
    || log "  · default incoming policy is '${DEFAULT_INCOMING:-unknown}'; 'deny' is safer"
  log "  · ufw limit ${SSH_PORT}/tcp        rate-limits SSH connection attempts"
  log "  · ufw deny ${SYSLOG_PORT}/tcp      belt-and-braces; rsyslog binds 127.0.0.1 already"
  log "  · ufw deny 5432/tcp        belt-and-braces; postgres uses a unix socket only"
fi

if ! (( ACTIVE )); then
  log ""
  warn "ufw is INACTIVE. This script has not enabled it, because enabling a"
  warn "firewall on a host running other services can cut them off without warning."
  warn "Review 'ufw status numbered', then enable it yourself: sudo ufw enable"
fi

#--- Report what is actually exposed, regardless of ufw -----------------------
log ""
log "listening on non-loopback addresses:"
ss -ltnH 2>/dev/null | awk '{print $4}' \
  | grep -vE '^(127\.|\[::1\]|\[?::1\]?)' \
  | sort -u | sed 's/^/    /' >&2 || true

for p in "$SYSLOG_PORT" 5432; do
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "(0\.0\.0\.0|\[::\]):${p}\$"; then
    warn "port ${p} is bound to all interfaces but should be loopback-only"
  fi
done
