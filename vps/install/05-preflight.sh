#!/usr/bin/env bash
# Check this host can host the stack before anything is installed.
#
# Written for a VPS that already runs other things: the failure mode this
# prevents is a service silently failing to bind halfway through an install,
# or worse, this stack taking a port something else was already using.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env

problems=0

log "checking for port conflicts"

# port_owner prints what is listening on a port, or nothing.
port_owner() {
  ss -ltnpH 2>/dev/null | awk -v p=":$1\$" '$4 ~ p {print $4" "$6}' | head -n1
}

# check_port <port> <what> <env-var-to-change>
check_port() {
  local port="$1" what="$2" var="$3" owner
  owner="$(port_owner "$port")"
  if [[ -z "$owner" ]]; then
    log "  ${port} free (${what})"
    return 0
  fi
  # Our own services re-binding on a re-run is expected, not a conflict.
  if [[ "$owner" == *"$what"* ]]; then
    log "  ${port} already held by ${what} — fine, this is a re-run"
    return 0
  fi
  warn "  ${port} is IN USE and wanted by ${what}"
  warn "      holder: ${owner}"
  [[ -n "$var" ]] && warn "      change ${var} in $HUB_ENV to a free port"
  problems=$((problems + 1))
}

check_port "${NTFY_PORT:-2586}"     ntfy           NTFY_PORT
check_port "${MINIFLUX_PORT:-8080}" miniflux       MINIFLUX_PORT
check_port "${CD_PORT:-5000}"       changedetection CD_PORT
check_port "${HC_PORT:-8000}"       healthchecks   HC_PORT
check_port "${RSS_RELAY_LISTEN##*:}" rss-relay     RSS_RELAY_LISTEN
check_port "${SYSLOG_TLS_PORT:-6514}" rsyslog      SYSLOG_TLS_PORT
check_port "${ACME_HTTP_PORT:-8402}" certbot       ACME_HTTP_PORT

# :443 is expected to be held by an existing HAProxy; anything else is a clash.
log "checking :443"
owner443="$(port_owner 443)"
if [[ -z "$owner443" ]]; then
  log "  443 free"
elif [[ "$owner443" == *haproxy* ]]; then
  log "  443 held by haproxy — expected; its config will be regenerated (and the"
  log "      existing one backed up if it was not written by this project)"
else
  warn "  443 is held by something other than haproxy: $owner443"
  warn "      HAProxy is the entry point for this stack and needs :443"
  problems=$((problems + 1))
fi

# Ports the passthrough backends forward to must actually have something behind
# them, or those domains will fail in a way that looks like a proxy bug.
log "checking TLS passthrough targets referenced in haproxy.cfg.tmpl"
while read -r target; do
  [[ -n "$target" ]] || continue
  p="${target##*:}"
  if [[ -n "$(port_owner "$p")" ]]; then
    log "  ${target} is being served"
  else
    warn "  ${target} has nothing listening — the domain routed to it will fail"
  fi
done < <(grep -oE 'server srv[0-9]+ 127\.0\.0\.1:[0-9]+' "$REPO_ROOT/vps/haproxy/haproxy.cfg.tmpl" | awk '{print $3}')

log "checking for conflicting package state"
for unit in ntfy miniflux; do
  if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 \
     && systemctl is-enabled --quiet "${unit}.service" 2>/dev/null; then
    log "  ${unit}.service already present — it will be reconfigured, not duplicated"
  fi
done

if (( problems )); then
  die "$problems conflict(s) found. Resolve them (usually by changing a port in
  $HUB_ENV) and re-run. Nothing has been installed."
fi

log "preflight passed"
