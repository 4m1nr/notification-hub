#!/usr/bin/env bash
# Renew certificates that expire within a short, configurable window.
#
# This replaces certbot's stock timer, which renews at 30 days out. Running every
# 6 hours against a 3-day threshold keeps certificates fresh without the churn of
# monthly reissues, and gives roughly a dozen retry opportunities before a cert
# would actually expire.
set -euo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
DOMAINS_MAP="${DOMAINS_MAP:-/etc/notification-hub/domains.map}"
LE_LIVE="${LE_LIVE:-/etc/letsencrypt/live}"

[[ -f "$HUB_ENV" ]] && { set -a; source "$HUB_ENV"; set +a; }

# Days before expiry at which we force a renewal.
THRESHOLD_DAYS="${CERT_RENEW_THRESHOLD_DAYS:-3}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { printf '[check-cert-renewal] %s\n' "$*" >&2; }
die() { printf '[check-cert-renewal] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOMAINS_MAP" ]] || die "$DOMAINS_MAP not found"
# --dry-run only inspects expiry dates, so it stays useful for checking the
# table and thresholds from a workstation without certbot installed.
if (( ! DRY_RUN )); then
  command -v certbot >/dev/null || die "certbot not installed"
fi

threshold_seconds=$(( THRESHOLD_DAYS * 86400 ))
log "threshold: ${THRESHOLD_DAYS} day(s)"

renewed_any=0

while read -r domain _dest _owner _format _service _rest; do
  [[ -z "${domain:-}" || "${domain:0:1}" == "#" ]] && continue

  cert="$LE_LIVE/$domain/fullchain.pem"
  if [[ ! -f "$cert" ]]; then
    log "$domain: no certificate issued yet — run certbot certonly for it first"
    continue
  fi

  # -checkend exits non-zero when the certificate expires within the window.
  if openssl x509 -in "$cert" -noout -checkend "$threshold_seconds" >/dev/null 2>&1; then
    expiry="$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)"
    log "$domain: OK (expires $expiry)"
    continue
  fi

  log "$domain: expires within ${THRESHOLD_DAYS}d — renewing"
  if (( DRY_RUN )); then
    log "$domain: dry run, not renewing"
    continue
  fi

  # --force-renewal because certbot would otherwise decline: by its own 30-day
  # rule the certificate is not due, but by ours it is.
  if certbot renew --cert-name "$domain" --force-renewal --non-interactive --quiet; then
    log "$domain: renewed"
    renewed_any=1
  else
    log "$domain: RENEWAL FAILED"
    # Keep going: one failing domain must not block the others.
  fi
done < "$DOMAINS_MAP"

if (( renewed_any )); then
  log "renewals completed; deploy hook has queued any needed restarts"
fi
