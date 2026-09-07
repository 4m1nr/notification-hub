#!/usr/bin/env bash
# certbot deploy hook: copy renewed certificates to the paths each service reads.
#
# Two deliberate properties:
#
#  1. No service ever reads from /etc/letsencrypt/live directly. Every consumer
#     has its own path with its own ownership, so a service that is compromised
#     cannot read another service's key.
#
#  2. This script NEVER restarts or reloads anything. It drops a flag file and
#     returns. Applying the change is a separate, scheduled step — so a 3am
#     renewal cannot cause a 3am surprise restart.
set -euo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
HUB_STATE="${HUB_STATE:-/var/lib/notification-hub}"
DOMAINS_MAP="${DOMAINS_MAP:-/etc/notification-hub/domains.map}"
LE_LIVE="${LE_LIVE:-/etc/letsencrypt/live}"
PENDING_DIR="$HUB_STATE/pending-restart"

[[ -f "$HUB_ENV" ]] && { set -a; source "$HUB_ENV"; set +a; }

log()  { printf '[distribute-certs] %s\n' "$*" >&2; }
die()  { printf '[distribute-certs] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOMAINS_MAP" ]] || die "$DOMAINS_MAP not found"
mkdir -p "$PENDING_DIR"; chmod 0750 "$PENDING_DIR"

# certbot sets RENEWED_LINEAGE for a single renewal. With no such variable we
# process every domain in the table, which is what a manual run should do.
only_lineage=""
if [[ -n "${RENEWED_LINEAGE:-}" ]]; then
  only_lineage="$(basename "$RENEWED_LINEAGE")"
  log "invoked by certbot for lineage: $only_lineage"
fi

changed_services=()

# install_if_changed writes src to dest only when the content differs, so an
# unchanged certificate does not queue a pointless restart.
install_if_changed() {
  local src="$1" dest="$2" mode="$3" owner="$4"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    chmod "$mode" "$dest"; chown "$owner" "$dest"
    return 1
  fi
  install -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$src" "$dest"
  log "updated $dest"
  return 0
}

while read -r domain dest owner format service _rest; do
  # Skip blanks and comments.
  [[ -z "${domain:-}" || "${domain:0:1}" == "#" ]] && continue
  [[ -n "${dest:-}" && -n "${owner:-}" && -n "${format:-}" && -n "${service:-}" ]] \
    || die "malformed line for domain '$domain' in $DOMAINS_MAP"

  if [[ -n "$only_lineage" && "$domain" != "$only_lineage" ]]; then
    continue
  fi

  live="$LE_LIVE/$domain"
  if [[ ! -f "$live/fullchain.pem" || ! -f "$live/privkey.pem" ]]; then
    log "no certificate yet for $domain — skipping"
    continue
  fi

  group="${owner##*:}"
  changed=0

  if [[ "$format" == "split" || "$format" == "both" ]]; then
    mkdir -p "$dest"; chmod 0750 "$dest"; chown "$owner" "$dest"
    # The chain is public; the key is not. Different modes on purpose.
    install_if_changed "$live/fullchain.pem" "$dest/fullchain.pem" 0644 "$owner" && changed=1
    install_if_changed "$live/privkey.pem"   "$dest/privkey.pem"   0640 "$owner" && changed=1
  fi

  if [[ "$format" == "combined" || "$format" == "both" ]]; then
    # HAProxy wants one file per domain containing the chain followed by the key.
    combined_dir="/etc/certs/proxy/combined"
    mkdir -p "$combined_dir"; chmod 0750 "$combined_dir"; chown "root:$group" "$combined_dir"

    tmp="$(mktemp)"
    chmod 0600 "$tmp"
    cat "$live/fullchain.pem" "$live/privkey.pem" > "$tmp"
    install_if_changed "$tmp" "$combined_dir/$domain.pem" 0640 "root:$group" && changed=1
    rm -f "$tmp"
  fi

  if (( changed )) && [[ "$service" != "none" ]]; then
    changed_services+=("$service")
  fi
done < "$DOMAINS_MAP"

# Queue, do not act. apply-pending-restarts.sh drains these on its own schedule.
if (( ${#changed_services[@]} )); then
  for service in $(printf '%s\n' "${changed_services[@]}" | sort -u); do
    date -Is > "$PENDING_DIR/$service"
    chmod 0640 "$PENDING_DIR/$service"
    log "queued restart for: $service"
  done
else
  log "no certificate content changed; nothing queued"
fi
