#!/usr/bin/env bash
# Firewall rules this stack needs.
#
# Additive only: it adds allow rules for 80 and 443 and reports on everything
# else. It never changes the default policy, enables ufw, or removes a rule —
# this host runs other services, and silently reshaping its firewall is a good
# way to break them.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

apt_ensure ufw

install_file "$REPO_ROOT/vps/security/firewall.sh" "$HUB_PREFIX/bin/firewall.sh" 0750 root:root || true

# A wrong SSH port only matters for --harden (which rate-limits it); warn rather
# than refuse, since the default path cannot lock anyone out.
DETECTED_SSH_PORT="$(ss -ltnpH 2>/dev/null | grep sshd | awk '{split($4,a,":"); print a[length(a)]}' | sort -u | head -n1)"
if [[ -n "$DETECTED_SSH_PORT" && "$DETECTED_SSH_PORT" != "${SSH_PORT:-22}" ]]; then
  warn "sshd appears to listen on port $DETECTED_SSH_PORT, but SSH_PORT is ${SSH_PORT:-22}"
  warn "set SSH_PORT=$DETECTED_SSH_PORT in $HUB_ENV before running with --harden"
fi

"$HUB_PREFIX/bin/firewall.sh"

log ""
log "to apply the recommended hardening once you have checked it against your"
log "other services:  $HUB_PREFIX/bin/firewall.sh --dry-run   then   --harden"
