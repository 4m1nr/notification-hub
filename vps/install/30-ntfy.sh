#!/usr/bin/env bash
# ntfy: the hub every other component publishes into.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars NTFY_DOMAIN PG_NTFY_PASSWORD

# Official apt repository — ntfy is not in Ubuntu's archive.
if ! command -v ntfy >/dev/null; then
  log "adding ntfy apt repository"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://archive.heckel.io/apt/pubkey.txt \
    | gpg --dearmor -o /etc/apt/keyrings/archive.heckel.io.gpg
  chmod a+r /etc/apt/keyrings/archive.heckel.io.gpg
  cat > /etc/apt/sources.list.d/archive.heckel.io.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/archive.heckel.io.gpg] https://archive.heckel.io/apt debian main
EOF
  apt-get update -qq
  apt_ensure ntfy
fi

ensure_dir /var/lib/ntfy 0700 ntfy:ntfy
ensure_dir /var/lib/ntfy/attachments 0700 ntfy:ntfy

# ntfy connects to PostgreSQL over the unix socket, which its own user must be
# able to traverse.
usermod -aG postgres ntfy 2>/dev/null || true

render "$REPO_ROOT/vps/ntfy/server.yml.tmpl" /etc/ntfy/server.yml 0640 root:ntfy || true

systemctl enable ntfy >/dev/null
systemctl restart ntfy
sleep 2
systemctl is-active --quiet ntfy || die "ntfy failed to start — check: journalctl -u ntfy -n 50"

TOPICS=(mail mattermost rss syslog site-changes system backup)

# ntfy's CLI reads /etc/ntfy/server.yml, so it operates on PostgreSQL too.
ntfy_user_exists() { ntfy user list 2>/dev/null | grep -qE "^user ${1}\b"; }

# The phone reads everything; nothing it holds can publish.
PHONE_PASSWORD="$(set_env_var NTFY_PHONE_PASSWORD "$(gen_secret 24)")"
if ! ntfy_user_exists phone; then
  log "creating ntfy user 'phone' (read-only)"
  NTFY_PASSWORD="$PHONE_PASSWORD" ntfy user add phone
fi
for topic in "${TOPICS[@]}"; do
  ntfy access phone "$topic" read-only >/dev/null
done

# One write-only publisher account, so a leaked publisher token cannot be used to
# read back mail subjects or work chat.
PUBLISHER_PASSWORD="$(set_env_var NTFY_PUBLISHER_PASSWORD "$(gen_secret 24)")"
if ! ntfy_user_exists publisher; then
  log "creating ntfy user 'publisher' (write-only)"
  NTFY_PASSWORD="$PUBLISHER_PASSWORD" ntfy user add publisher
fi
for topic in "${TOPICS[@]}"; do
  ntfy access publisher "$topic" write-only >/dev/null
done

# A separate token per source, so any one of them can be revoked on its own.
for var in NTFY_TOKEN_MAIL NTFY_TOKEN_MATTERMOST NTFY_TOKEN_RSS \
           NTFY_TOKEN_SYSLOG NTFY_TOKEN_SYSTEM NTFY_TOKEN_BACKUP NTFY_TOKEN_SITECHANGES; do
  if ! grep -qE "^${var}=" "$HUB_ENV"; then
    token="$(ntfy token add --expires=never --label="$var" publisher | grep -oE 'tk_[A-Za-z0-9]+' | head -n1)"
    [[ -n "$token" ]] || die "failed to create ntfy token for $var"
    set_env_var "$var" "$token" >/dev/null
  fi
done

set_env_var NTFY_URL "https://${NTFY_DOMAIN}" >/dev/null

log "ntfy ready — topics: ${TOPICS[*]}"
log "phone login: user 'phone', password in $HUB_ENV (NTFY_PHONE_PASSWORD)"
