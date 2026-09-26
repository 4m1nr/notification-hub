#!/usr/bin/env bash
# Issue a certificate without fighting HAProxy for :80.
#
#   issue-cert.sh <domain> [<extra-domain>...]   issue one lineage, named after
#                                                the first domain, and distribute
#   issue-cert.sh --pin-renewal-port             point every existing standalone
#                                                lineage at ACME_HTTP_PORT
#
# certbot's standalone authenticator binds :80 unless told otherwise, and once
# HAProxy is running it owns :80 — so a bare `certbot certonly --standalone`
# fails with "Could not bind TCP port 80". HAProxy forwards
# /.well-known/acme-challenge/ to ACME_HTTP_PORT, so certbot belongs there.
# The one exception is the very first issuance, before HAProxy exists: then
# nothing forwards anything and certbot must take :80 itself.
set -euo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
DOMAINS_MAP="${DOMAINS_MAP:-/etc/notification-hub/domains.map}"
LE_RENEWAL="${LE_RENEWAL:-/etc/letsencrypt/renewal}"
HUB_PREFIX="${HUB_PREFIX:-/opt/notification-hub}"

# shellcheck disable=SC1090
[[ -f "$HUB_ENV" ]] && { set -a; source "$HUB_ENV"; set +a; }
ACME_HTTP_PORT="${ACME_HTTP_PORT:-8402}"

log() { printf '[issue-cert] %s\n' "$*" >&2; }
die() { printf '[issue-cert] ERROR: %s\n' "$*" >&2; exit 1; }

# pin_renewal_port makes a lineage renew on ACME_HTTP_PORT whoever runs the
# renewal. A lineage first issued on :80 records http01_port = 80, and a later
# `certbot renew` without --http-01-port would try :80 again and collide with
# HAProxy.
pin_renewal_port() {
  local conf="$1"
  grep -qE '^authenticator *= *standalone' "$conf" || return 0
  if grep -qE '^http01_port *=' "$conf"; then
    grep -qE "^http01_port *= *${ACME_HTTP_PORT}\$" "$conf" && return 0
    sed -i -E "s/^http01_port *=.*/http01_port = ${ACME_HTTP_PORT}/" "$conf"
  else
    sed -i -E "/^\[renewalparams\]/a http01_port = ${ACME_HTTP_PORT}" "$conf"
  fi
  log "$(basename "$conf" .conf): renewals now use port $ACME_HTTP_PORT"
}

if [[ "${1:-}" == "--pin-renewal-port" ]]; then
  [[ -d "$LE_RENEWAL" ]] || exit 0
  for conf in "$LE_RENEWAL"/*.conf; do
    [[ -f "$conf" ]] && pin_renewal_port "$conf"
  done
  exit 0
fi

(( $# )) || die "usage: $0 <domain> [<extra-domain>...]   |   $0 --pin-renewal-port"
[[ ${EUID} -eq 0 ]] || die "must run as root (try: sudo $0 $*)"
command -v certbot >/dev/null || die "certbot not installed"
[[ -n "${ACME_EMAIL:-}" ]] || die "ACME_EMAIL is not set in $HUB_ENV"

# Who holds :80 decides where certbot listens.
holder="$(ss -ltnpH 'sport = :80' 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n1 | cut -d'"' -f2 || true)"
case "$holder" in
  "")
    port=80
    log ":80 is free (HAProxy not running yet) — certbot will bind it directly" ;;
  haproxy)
    port="$ACME_HTTP_PORT"
    log ":80 is HAProxy's — certbot binds $port and HAProxy forwards the challenge" ;;
  *)
    die ":80 is held by '$holder', which does not forward ACME challenges to $ACME_HTTP_PORT" ;;
esac

cert_name="$1"
domain_args=()
for d in "$@"; do domain_args+=(-d "$d"); done

# --http-01-port is explicit on purpose: /etc/letsencrypt/cli.ini defaults it
# to ACME_HTTP_PORT, which is wrong for the first issuance on a bare :80.
certbot certonly --standalone --preferred-challenges http \
  --http-01-port "$port" --cert-name "$cert_name" \
  --non-interactive --agree-tos --email "$ACME_EMAIL" --keep-until-expiring \
  "${domain_args[@]}"

pin_renewal_port "$LE_RENEWAL/$cert_name.conf"

if [[ -f "$DOMAINS_MAP" ]] && ! awk '!/^#/ {print $1}' "$DOMAINS_MAP" | grep -qxF "$cert_name"; then
  log "WARNING: $cert_name is not in $DOMAINS_MAP, so it will not be copied anywhere."
  log "  Add a line for it, then run: $HUB_PREFIX/bin/distribute-certs.sh"
  exit 0
fi

# certbot's deploy hook only fires on renewal, not on a first issuance.
RENEWED_LINEAGE="/etc/letsencrypt/live/$cert_name" "$HUB_PREFIX/bin/distribute-certs.sh"
log "done. HAProxy picks the certificate up at the next queued reload"
log "  (or now: sudo $HUB_PREFIX/bin/apply-pending-restarts.sh)"
