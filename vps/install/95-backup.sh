#!/usr/bin/env bash
# Daily encrypted backup to a private Telegram chat.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars AGE_RECIPIENT TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

BACKUP_TIME="${BACKUP_TIME:-03:30:00}"
CERT_RESTART_TIME="${CERT_RESTART_TIME:-04:30:00}"
export BACKUP_TIME

if [[ "$BACKUP_TIME" == "$CERT_RESTART_TIME" ]]; then
  die "BACKUP_TIME and CERT_RESTART_TIME are identical ($BACKUP_TIME) — give them separate windows"
fi

apt_ensure age jq

ensure_dir /var/backups/notification-hub 0700 root:root

install_file "$REPO_ROOT/vps/backup/backup.sh" "$HUB_PREFIX/bin/backup.sh" 0750 root:root || true

install_unit "$REPO_ROOT/vps/systemd/backup.service"
install_unit "$REPO_ROOT/vps/systemd/backup.timer.tmpl"
systemd_reload
enable_now backup.timer

log "backup scheduled daily at $BACKUP_TIME"
log "verify now with a dry run: $HUB_PREFIX/bin/backup.sh --dry-run"
