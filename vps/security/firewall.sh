#!/usr/bin/env bash
# Baseline firewall: deny inbound by default, allow only what is deliberately
# published.
#
# This is the layer that makes "the syslog collector is local-only" enforceable
# rather than merely configured: even if rsyslog were misconfigured to bind
# 0.0.0.0, nothing could reach it from outside.
set -euo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
[[ -f "$HUB_ENV" ]] && { set -a; source "$HUB_ENV"; set +a; }

SSH_PORT="${SSH_PORT:-22}"

log() { printf '[firewall] %s\n' "$*" >&2; }
die() { printf '[firewall] ERROR: %s\n' "$*" >&2; exit 1; }

command -v ufw >/dev/null || die "ufw not installed"

log "setting default policies"
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null

# SSH first, and before enabling — enabling with no SSH rule locks you out of a
# remote VPS permanently.
log "allowing ssh on ${SSH_PORT}"
ufw allow "${SSH_PORT}/tcp" comment 'ssh' >/dev/null

log "allowing http/https"
ufw allow 80/tcp  comment 'acme http-01' >/dev/null
ufw allow 443/tcp comment 'haproxy' >/dev/null

# Rate-limit SSH connections at the firewall as well as in fail2ban: ufw's limit
# rule drops an address making more than 6 connections in 30 seconds, which
# blunts a burst before fail2ban has even parsed the log.
log "rate-limiting ssh"
ufw limit "${SSH_PORT}/tcp" >/dev/null

# Explicitly deny the syslog port from the network. rsyslog binds 127.0.0.1 so
# this is redundant today — that is the point. It is here so a future edit to
# the rsyslog config cannot quietly publish the collector.
log "denying syslog (${SYSLOG_TLS_PORT:-6514}) from the network"
ufw --force delete allow "${SYSLOG_TLS_PORT:-6514}/tcp" >/dev/null 2>&1 || true
ufw deny "${SYSLOG_TLS_PORT:-6514}/tcp" comment 'syslog is loopback-only' >/dev/null

# PostgreSQL listens on a unix socket only; deny the port for the same reason.
ufw deny 5432/tcp comment 'postgres is socket-only' >/dev/null

if ufw status | head -1 | grep -q inactive; then
  log "enabling ufw"
  ufw --force enable >/dev/null
else
  ufw --force reload >/dev/null
fi

log "current policy:"
ufw status verbose | sed 's/^/    /' >&2
