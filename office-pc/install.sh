#!/usr/bin/env bash
# Install the office-PC watchers.
#
# Same idiom as the VPS: system users, systemd units, an EnvironmentFile per
# service. Run this on the office machine, from a checkout of this repo.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../vps/install" && pwd)/lib.sh"
require_root

command -v go >/dev/null || die "go toolchain required to build the watchers (apt install golang-go)"

ensure_dir /etc/notification-hub 0750 root:root
ensure_sysuser nhub /var/lib/notification-hub
ensure_dir /var/lib/notification-hub 0750 nhub:nhub

go_build_install mail-watcher
go_build_install mattermost-watcher

# Seed the environment files on first install; never overwrite real credentials.
for svc in mail-watcher mattermost-watcher; do
  target="/etc/notification-hub/${svc}.env"
  if [[ ! -f "$target" ]]; then
    install -o root -g nhub -m 0640 "$REPO_ROOT/office-pc/${svc}.env.example" "$target"
    warn "created $target — fill it in before starting ${svc}"
  else
    chown root:nhub "$target"; chmod 0640 "$target"
  fi
done

install_unit "$REPO_ROOT/office-pc/systemd/mail-watcher.service"
install_unit "$REPO_ROOT/office-pc/systemd/mattermost-watcher.service"

# Keep the machine awake. Without this the watchers are perfectly healthy and
# simply not running, which is the failure mode hardest to notice.
ensure_dir /etc/systemd/sleep.conf.d 0755 root:root
ensure_dir /etc/systemd/logind.conf.d 0755 root:root
install_file "$REPO_ROOT/office-pc/systemd/no-sleep.conf" \
  /etc/systemd/sleep.conf.d/notification-hub.conf && SYSTEMD_DIRTY=1
install_file "$REPO_ROOT/office-pc/systemd/logind-no-sleep.conf" \
  /etc/systemd/logind.conf.d/notification-hub.conf && SYSTEMD_DIRTY=1

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
systemd_reload

# Only start services whose credentials have actually been filled in — starting a
# watcher with a blank password just produces a restart loop.
for svc in mail-watcher mattermost-watcher; do
  env_file="/etc/notification-hub/${svc}.env"
  if grep -qE '^(IMAP_PASSWORD|MATTERMOST_TOKEN)=$' "$env_file"; then
    warn "$svc not started: credentials are still blank in $env_file"
    continue
  fi
  enable_now "${svc}.service"
done

log "office PC setup complete"
log "check status with: systemctl status mail-watcher mattermost-watcher"
