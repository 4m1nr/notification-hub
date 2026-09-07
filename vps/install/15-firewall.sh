#!/usr/bin/env bash
# Baseline firewall. Runs early so the box is not wide open while the rest of
# the stack is being installed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

apt_ensure ufw

install_file "$REPO_ROOT/vps/security/firewall.sh" "$HUB_PREFIX/bin/firewall.sh" 0750 root:root || true

# Detect a non-default SSH port so enabling ufw cannot lock you out.
DETECTED_SSH_PORT="$(ss -ltnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]}' | head -n1)"
if [[ -n "$DETECTED_SSH_PORT" && "$DETECTED_SSH_PORT" != "${SSH_PORT:-22}" ]]; then
  warn "sshd appears to listen on port $DETECTED_SSH_PORT, not ${SSH_PORT:-22}"
  warn "set SSH_PORT=$DETECTED_SSH_PORT in $HUB_ENV and re-run, or you will be locked out"
  die "refusing to enable the firewall with a possibly wrong SSH port"
fi

"$HUB_PREFIX/bin/firewall.sh"
log "firewall active"
