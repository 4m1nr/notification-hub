#!/usr/bin/env bash
# Install the whole VPS side, in dependency order.
#
# Every step is idempotent, so re-running after a fix is safe and cheap. Steps
# can also be run individually — the numbering is the order, not a requirement to
# run them together.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source vps/install/lib.sh
require_root

STEPS=(
  10-packages.sh
  20-postgres.sh
  30-ntfy.sh
  40-miniflux.sh
  50-go-services.sh
  70-certs.sh
  80-haproxy.sh
  90-docker-apps.sh
  60-syslog.sh
  95-backup.sh
)

usage() {
  cat >&2 <<EOF
usage: $0 [step ...]

With no arguments, runs every step in order:
  ${STEPS[*]}

Note the ordering: certificates (70) and HAProxy (80) come before syslog (60),
because the syslog TLS listener needs a certificate that 70 distributes.

Examples:
  sudo $0                      # full install
  sudo $0 30-ntfy.sh           # just ntfy
  sudo $0 70-certs.sh 80-haproxy.sh
EOF
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

if [[ -f "$HUB_ENV" ]]; then
  log "using $HUB_ENV"
else
  die "$HUB_ENV not found. Create it first:
  install -d -m 0750 /etc/notification-hub
  install -m 0600 .env.example $HUB_ENV
  \${EDITOR:-vi} $HUB_ENV"
fi

selected=("$@")
(( ${#selected[@]} )) || selected=("${STEPS[@]}")

for step in "${selected[@]}"; do
  script="vps/install/$step"
  [[ -f "$script" ]] || die "no such step: $step"
  printf '\n\033[1m===== %s =====\033[0m\n' "$step" >&2
  bash "$script"
done

printf '\n\033[1m===== done =====\033[0m\n' >&2
log "next steps:"
log "  1. docs/ntfy-topics.md         — subscribe the phone"
log "  2. docs/healthchecks-setup.md  — create the checks, then fill HC_PING_URL_* in $HUB_ENV"
log "  3. docs/miniflux-android.md    — connect an Android reader"
log "  4. docs/changedetection-login.md — set up a watch behind a login"
log "  5. $HUB_PREFIX/bin/backup.sh --dry-run  — verify backups before trusting them"
