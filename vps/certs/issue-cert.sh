#!/usr/bin/env bash
# Issue and manage certificates without fighting HAProxy for :80.
#
#   issue-cert.sh [--cert-name <name>] [--dns] <domain> [<domain>...]
#       Issue (or change the names on) one lineage and distribute it. Several
#       domains make one multi-name (SAN) certificate. A wildcard such as
#       '*.example.com' — quote it, or the shell expands it — is validated over
#       DNS, as is everything when --dns is given. The lineage is named after
#       the first domain, minus any leading '*.', unless --cert-name says
#       otherwise; that name is what goes in domains.map.
#   issue-cert.sh --list
#       Every lineage with its names, challenge type, expiry and whether
#       domains.map distributes it.
#   issue-cert.sh --remove <name>
#       Revoke nothing, but delete a lineage and the copy HAProxy serves.
#   issue-cert.sh --pin-renewal-port
#       Point every existing standalone lineage at ACME_HTTP_PORT.
#
# HTTP-01: certbot's standalone authenticator binds :80 unless told otherwise,
# and once HAProxy is running it owns :80 — so a bare `certbot certonly
# --standalone` fails with "Could not bind TCP port 80". HAProxy forwards
# /.well-known/acme-challenge/ to ACME_HTTP_PORT, so certbot belongs there.
# The one exception is the very first issuance, before HAProxy exists: then
# nothing forwards anything and certbot must take :80 itself.
#
# DNS-01: Let's Encrypt only issues wildcards against a TXT record, so those go
# through a certbot DNS plugin (ACME_DNS_PLUGIN) using an API credential in
# ACME_DNS_CREDENTIALS. The plugin and credential path are recorded in the
# lineage's renewal config, so renewals need nothing further.
set -euo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
DOMAINS_MAP="${DOMAINS_MAP:-/etc/notification-hub/domains.map}"
LE_RENEWAL="${LE_RENEWAL:-/etc/letsencrypt/renewal}"
LE_LIVE="${LE_LIVE:-/etc/letsencrypt/live}"
HUB_PREFIX="${HUB_PREFIX:-/opt/notification-hub}"
HUB_STATE="${HUB_STATE:-/var/lib/notification-hub}"
COMBINED_DIR="${COMBINED_DIR:-/etc/certs/proxy/combined}"

# shellcheck disable=SC1090
[[ -f "$HUB_ENV" ]] && { set -a; source "$HUB_ENV"; set +a; }
ACME_HTTP_PORT="${ACME_HTTP_PORT:-8402}"
ACME_DNS_PLUGIN="${ACME_DNS_PLUGIN:-}"
ACME_DNS_CREDENTIALS="${ACME_DNS_CREDENTIALS:-/etc/letsencrypt/dns/${ACME_DNS_PLUGIN}.ini}"
ACME_DNS_PROPAGATION_SECONDS="${ACME_DNS_PROPAGATION_SECONDS:-}"

log() { printf '[issue-cert] %s\n' "$*" >&2; }
die() { printf '[issue-cert] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
usage: $0 [--cert-name <name>] [--dns] <domain> [<domain>...]
       $0 --list
       $0 --remove <name>
       $0 --pin-renewal-port
EOF
  exit 2
}

# pin_renewal_port makes a lineage renew on ACME_HTTP_PORT whoever runs the
# renewal. A lineage first issued on :80 records http01_port = 80, and a later
# `certbot renew` without --http-01-port would try :80 again and collide with
# HAProxy. DNS lineages never touch a port and are left alone.
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

# in_domains_map succeeds when the lineage has an active line in domains.map.
in_domains_map() {
  [[ -f "$DOMAINS_MAP" ]] && awk '!/^[[:space:]]*#/ {print $1}' "$DOMAINS_MAP" | grep -qxF "$1"
}

list_certs() {
  [[ -d "$LE_RENEWAL" ]] || { log "no lineages (no $LE_RENEWAL)"; return 0; }
  local conf name cert auth names end days mapped now
  now="$(date +%s)"
  printf '%-30s %-16s %-6s %-8s %s\n' LINEAGE CHALLENGE DAYS MAPPED NAMES
  for conf in "$LE_RENEWAL"/*.conf; do
    [[ -f "$conf" ]] || continue
    name="$(basename "$conf" .conf)"
    cert="$LE_LIVE/$name/fullchain.pem"
    auth="$(sed -nE 's/^authenticator *= *//p' "$conf" | head -n1)"
    [[ "$auth" == standalone ]] && auth=http-01
    if [[ -f "$cert" ]]; then
      names="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | sed -nE 's/^ *DNS://p' | paste -sd' ' -)"
      end="$(date -d "$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)" +%s)"
      days=$(( (end - now) / 86400 ))
    else
      names="(certificate missing)"; days="-"
    fi
    mapped=no; in_domains_map "$name" && mapped=yes
    printf '%-30s %-16s %-6s %-8s %s\n' "$name" "${auth:-?}" "$days" "$mapped" "$names"
  done
}

remove_cert() {
  local name="$1"
  [[ ${EUID} -eq 0 ]] || die "must run as root (try: sudo $0 --remove $name)"
  [[ -f "$LE_RENEWAL/$name.conf" ]] || die "no lineage named '$name' (see: $0 --list)"
  if in_domains_map "$name"; then
    die "'$name' still has a line in $DOMAINS_MAP — remove or comment it out first,
  so nothing tries to renew or distribute it afterwards"
  fi

  local combined="$COMBINED_DIR/$name.pem"
  if [[ -f "$combined" ]]; then
    # HAProxy refuses to start with an empty crt directory, and a reload would
    # then fail, so the last certificate cannot go.
    local others
    others="$(find "$COMBINED_DIR" -maxdepth 1 -name '*.pem' ! -name "$name.pem" | wc -l)"
    (( others > 0 )) || die "$combined is the only certificate HAProxy has; issue its replacement first"
  fi

  certbot delete --cert-name "$name" --non-interactive
  if [[ -f "$combined" ]]; then
    rm -f "$combined"
    mkdir -p "$HUB_STATE/pending-restart"
    date -Is > "$HUB_STATE/pending-restart/haproxy"
    log "removed $combined; HAProxy drops it at the next queued reload"
    log "  (or now: sudo $HUB_PREFIX/bin/apply-pending-restarts.sh)"
  fi
  log "deleted lineage $name. Split copies under its old domains.map dest, if any, were left in place."
}

pin_all=0 dns=0 cert_name=""
domains=()
while (( $# )); do
  case "$1" in
    --pin-renewal-port) pin_all=1 ;;
    --list)             list_certs; exit 0 ;;
    --remove)           [[ -n "${2:-}" ]] || usage; remove_cert "$2"; exit 0 ;;
    --dns)              dns=1 ;;
    --cert-name)        [[ -n "${2:-}" ]] || usage; cert_name="$2"; shift ;;
    -h|--help)          usage ;;
    -*)                 die "unknown option $1" ;;
    *)                  domains+=("${1,,}") ;;
  esac
  shift
done

if (( pin_all )); then
  [[ -d "$LE_RENEWAL" ]] || exit 0
  for conf in "$LE_RENEWAL"/*.conf; do
    [[ -f "$conf" ]] && pin_renewal_port "$conf"
  done
  exit 0
fi

(( ${#domains[@]} )) || usage
[[ ${EUID} -eq 0 ]] || die "must run as root (try: sudo $0 ...)"
command -v certbot >/dev/null || die "certbot not installed"
[[ -n "${ACME_EMAIL:-}" ]] || die "ACME_EMAIL is not set in $HUB_ENV"

for d in "${domains[@]}"; do
  [[ "$d" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]+$ ]] \
    || die "'$d' is not a domain name (a wildcard may only be a leading '*.')"
  [[ "$d" == \*.* ]] && dns=1
done

# certbot names a lineage after the first domain; a lineage name cannot carry
# the '*', and the name has to be predictable because domains.map refers to it.
cert_name="${cert_name:-${domains[0]#\*.}}"
[[ "$cert_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "lineage name '$cert_name' must be letters, digits, '.', '_' or '-'"

challenge_args=()
if (( dns )); then
  [[ -n "$ACME_DNS_PLUGIN" ]] || die "DNS validation needed (wildcard or --dns) but ACME_DNS_PLUGIN is not set in $HUB_ENV.
  See docs/certificates.md, then re-run: sudo ./bootstrap.sh 70-certs.sh"
  [[ "$ACME_DNS_PLUGIN" =~ ^[a-z0-9-]+$ ]] || die "ACME_DNS_PLUGIN='$ACME_DNS_PLUGIN' is not a plugin name"
  certbot plugins 2>/dev/null | grep -qE "^\* dns-${ACME_DNS_PLUGIN}\$" \
    || die "certbot plugin dns-$ACME_DNS_PLUGIN is not installed (sudo ./bootstrap.sh 70-certs.sh installs it)"
  challenge_args=(--authenticator "dns-$ACME_DNS_PLUGIN")
  # route53 reads the standard AWS credential chain instead of a file.
  if [[ "$ACME_DNS_PLUGIN" != route53 ]]; then
    [[ -f "$ACME_DNS_CREDENTIALS" ]] || die "DNS credentials file $ACME_DNS_CREDENTIALS does not exist"
    # certbot stores this path in the renewal config, so it must stay put and
    # stay readable by root alone.
    chmod 0600 "$ACME_DNS_CREDENTIALS"
    challenge_args+=("--dns-$ACME_DNS_PLUGIN-credentials" "$ACME_DNS_CREDENTIALS")
  fi
  if [[ -n "$ACME_DNS_PROPAGATION_SECONDS" ]]; then
    challenge_args+=("--dns-$ACME_DNS_PLUGIN-propagation-seconds" "$ACME_DNS_PROPAGATION_SECONDS")
  fi
  log "validating over DNS with dns-$ACME_DNS_PLUGIN — :80 is not involved"
else
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
  # --http-01-port is explicit on purpose: /etc/letsencrypt/cli.ini defaults it
  # to ACME_HTTP_PORT, which is wrong for the first issuance on a bare :80.
  challenge_args=(--standalone --preferred-challenges http --http-01-port "$port")
fi

domain_args=()
for d in "${domains[@]}"; do domain_args+=(-d "$d"); done

# An existing lineage given a different set of names is reissued with exactly
# the names listed here — that is how names are added or dropped later.
if [[ -f "$LE_RENEWAL/$cert_name.conf" ]]; then
  log "$cert_name exists; it will carry exactly: ${domains[*]}"
fi

certbot certonly "${challenge_args[@]}" --cert-name "$cert_name" \
  --non-interactive --agree-tos --email "$ACME_EMAIL" --keep-until-expiring \
  "${domain_args[@]}"

pin_renewal_port "$LE_RENEWAL/$cert_name.conf"

if [[ -f "$DOMAINS_MAP" ]] && ! in_domains_map "$cert_name"; then
  log "WARNING: $cert_name is not in $DOMAINS_MAP, so it will not be copied anywhere."
  log "  Add a line whose first column is '$cert_name', then run: $HUB_PREFIX/bin/distribute-certs.sh"
  exit 0
fi

# certbot's deploy hook only fires on renewal, not on a first issuance.
RENEWED_LINEAGE="$LE_LIVE/$cert_name" "$HUB_PREFIX/bin/distribute-certs.sh"
log "done. HAProxy picks the certificate up at the next queued reload"
log "  (or now: sudo $HUB_PREFIX/bin/apply-pending-restarts.sh)"
