#!/usr/bin/env bash
# Daily backup: snapshot every service's state, encrypt it, and ship it to a
# private Telegram chat.
#
# Two rules shape this script:
#
#  1. The archive is encrypted BEFORE it leaves the box. Telegram's servers are
#     not a trusted vault, and this archive contains service configuration and
#     credentials.
#
#  2. Any failure notifies immediately on the ntfy `backup` topic rather than
#     waiting for a dead-man's-switch. This runs once a day; by the time a grace
#     period lapsed, a day of backups could already be silently lost.
set -euo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
[[ -f "$HUB_ENV" ]] && { set -a; source "$HUB_ENV"; set +a; }

BACKUP_DIR="${BACKUP_DIR:-/var/backups/notification-hub}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-3}"
COMPOSE_FILE="${COMPOSE_FILE:-/etc/notification-hub/docker/docker-compose.yml}"
# The Bot API caps a document upload at 50MB; stay under it with room to spare.
CHUNK_SIZE="${BACKUP_CHUNK_SIZE:-45M}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

STAMP="$(date +%F)"
STAGE=""
STEP="startup"

log() { printf '[backup] %s\n' "$*" >&2; }

# alert publishes straight to ntfy. It deliberately does not use any of our Go
# binaries: if the backup is broken, the notification path must be as simple as
# possible.
alert() {
  local text="$1"
  [[ -n "${NTFY_URL:-}" && -n "${NTFY_TOKEN_BACKUP:-}" ]] || return 0
  curl -fsS -m 20 \
    -H "Authorization: Bearer ${NTFY_TOKEN_BACKUP}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg t "${NTFY_TOPIC_BACKUP:-backup}" \
                 --arg ti "Backup failed: ${STEP}" \
                 --arg m "$text" \
                 '{topic:$t, title:$ti, message:$m, priority:5, tags:["rotating_light"]}')" \
    "$NTFY_URL" >/dev/null || true
}

cleanup() {
  local code=$?
  if (( code != 0 )); then
    log "FAILED during step: $STEP (exit $code)"
    alert "Step '${STEP}' failed with exit code ${code} on $(hostname). Check: journalctl -u backup.service -n 100"
    # Take the check down now rather than waiting out its grace period.
    [[ -n "${HC_PING_URL_BACKUP:-}" ]] && curl -fsS -m 10 -o /dev/null "${HC_PING_URL_BACKUP}/fail" || true
  fi
  # Always restart changedetection, even if we died mid-copy.
  if [[ "${CD_STOPPED:-0}" == "1" ]]; then
    docker compose -f "$COMPOSE_FILE" start changedetection >/dev/null 2>&1 || true
  fi
  [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf "$STAGE"
  exit "$code"
}
trap cleanup EXIT

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || { STEP="dependency check"; log "missing command: $cmd"; exit 1; }
  done
}

STEP="dependency check"
require tar age curl jq pg_dump split
: "${AGE_RECIPIENT:?AGE_RECIPIENT must be set in $HUB_ENV}"
if (( ! DRY_RUN )); then
  : "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN must be set in $HUB_ENV}"
  : "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID must be set in $HUB_ENV}"
fi

STEP="staging"
mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
STAGE="$(mktemp -d)"
chmod 0700 "$STAGE"
mkdir -p "$STAGE/postgres" "$STAGE/config" "$STAGE/changedetection"

#--- Databases ---------------------------------------------------------------
# All three services share one PostgreSQL instance, so this is three dumps and
# no downtime. pg_dump takes a consistent snapshot while the services keep running.
STEP="postgres dump"
log "dumping databases"
su - postgres -c "pg_dumpall --globals-only" > "$STAGE/postgres/globals.sql"
for db in ntfy miniflux healthchecks; do
  su - postgres -c "pg_dump -Fc '$db'" > "$STAGE/postgres/${db}.dump"
  log "  $db: $(stat -c%s "$STAGE/postgres/${db}.dump") bytes"
done

#--- changedetection.io ------------------------------------------------------
# The only service with no SQL backend: its state is a JSON datastore on disk,
# which must be quiesced to be copied consistently. A few seconds of downtime,
# once a day.
STEP="changedetection datastore"
if docker compose -f "$COMPOSE_FILE" ps --status running --services 2>/dev/null | grep -qx changedetection; then
  log "pausing changedetection for a consistent copy"
  docker compose -f "$COMPOSE_FILE" stop changedetection >/dev/null
  CD_STOPPED=1
  cp -a /var/lib/changedetection/. "$STAGE/changedetection/" 2>/dev/null || true
  docker compose -f "$COMPOSE_FILE" start changedetection >/dev/null
  CD_STOPPED=0
  log "changedetection resumed"
else
  cp -a /var/lib/changedetection/. "$STAGE/changedetection/" 2>/dev/null || true
fi

#--- Configuration -----------------------------------------------------------
STEP="config collection"
log "collecting configuration"
copy_if_present() {
  local src="$1" dest="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"
}

copy_if_present /etc/ntfy/server.yml            "$STAGE/config/ntfy/server.yml"
copy_if_present /etc/miniflux.conf              "$STAGE/config/miniflux.conf"
copy_if_present /etc/haproxy/haproxy.cfg        "$STAGE/config/haproxy/haproxy.cfg"
copy_if_present /etc/notification-hub/domains.map "$STAGE/config/domains.map"
copy_if_present "$HUB_ENV"                      "$STAGE/config/hub.env"
copy_if_present "$COMPOSE_FILE"                 "$STAGE/config/docker-compose.yml"

mkdir -p "$STAGE/config/rsyslog"
cp -a /etc/rsyslog.d/. "$STAGE/config/rsyslog/" 2>/dev/null || true

mkdir -p "$STAGE/config/systemd"
find /etc/systemd/system -maxdepth 1 \
  \( -name 'rss-relay*' -o -name 'cert-*' -o -name 'backup.*' -o -name 'hc-heartbeat*' \) \
  -exec cp -a {} "$STAGE/config/systemd/" \; 2>/dev/null || true

mkdir -p "$STAGE/config/cert-scripts"
cp -a /opt/notification-hub/bin/*.sh "$STAGE/config/cert-scripts/" 2>/dev/null || true

# Private keys are excluded on purpose: they are re-issuable from ACME in
# minutes, and shipping them to a chat app buys nothing but risk.
STEP="key exclusion check"
if find "$STAGE" -name '*.pem' -o -name '*.key' | grep -q .; then
  log "refusing to continue: private key material found in the staging area"
  find "$STAGE" -name '*.pem' -o -name '*.key' >&2
  exit 1
fi

cat > "$STAGE/MANIFEST.txt" <<EOF
notification-hub backup
host:    $(hostname)
created: $(date -Is)
contents:
  postgres/globals.sql       role definitions (pg_dumpall --globals-only)
  postgres/ntfy.dump         ntfy: users, ACLs, tokens, message cache (pg_dump -Fc)
  postgres/miniflux.dump     miniflux: feeds, categories, read state (pg_dump -Fc)
  postgres/healthchecks.dump healthchecks: check definitions and ping URLs (pg_dump -Fc)
  changedetection/           changedetection.io JSON datastore and history
  config/                    service configuration, systemd units, cert scripts

NOT included: TLS private keys. Re-issue them with certbot after a restore.
See docs/backup-restore.md for the restore procedure.
EOF

#--- Archive and encrypt -----------------------------------------------------
STEP="archive"
ARCHIVE="$BACKUP_DIR/backup-${STAMP}.tar.gz"
log "creating $ARCHIVE"
tar czf "$ARCHIVE" -C "$STAGE" .
chmod 0600 "$ARCHIVE"

STEP="encrypt"
ENCRYPTED="${ARCHIVE}.age"
log "encrypting to $ENCRYPTED"
age -r "$AGE_RECIPIENT" -o "$ENCRYPTED" "$ARCHIVE"
chmod 0600 "$ENCRYPTED"
# The plaintext archive has served its purpose; only the encrypted one is kept.
rm -f "$ARCHIVE"

SIZE_BYTES="$(stat -c%s "$ENCRYPTED")"
human_size() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1} bytes"; }
log "encrypted archive: $(human_size "$SIZE_BYTES")"

if (( DRY_RUN )); then
  log "dry run: skipping upload"
  log "verify with: age -d -i <key> $ENCRYPTED | tar tzf -"
  exit 0
fi

#--- Upload ------------------------------------------------------------------
# The Bot API caps uploads at 50MB, so anything larger is split into numbered
# parts and sent as separate documents. Restoring is a `cat` of the parts in
# order — see docs/backup-restore.md.
STEP="telegram upload"
send_document() {
  local file="$1" caption="$2"
  curl -fsS -m 600 \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "caption=${caption}" \
    -F "document=@${file}" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    | jq -e '.ok == true' >/dev/null
}

CHUNK_LIMIT=$(( 49 * 1024 * 1024 ))
if (( SIZE_BYTES > CHUNK_LIMIT )); then
  log "archive exceeds the Bot API limit; splitting into ${CHUNK_SIZE} parts"
  PARTS_DIR="$STAGE/parts"
  mkdir -p "$PARTS_DIR"
  split -b "$CHUNK_SIZE" -d -a 3 "$ENCRYPTED" "$PARTS_DIR/$(basename "$ENCRYPTED").part"

  total="$(find "$PARTS_DIR" -type f | wc -l)"
  index=0
  for part in "$PARTS_DIR"/*; do
    index=$(( index + 1 ))
    log "uploading part $index/$total"
    send_document "$part" "backup ${STAMP} — part ${index} of ${total} (cat all parts in order, then decrypt)"
  done
  log "uploaded $total parts"
else
  log "uploading single archive"
  send_document "$ENCRYPTED" "backup ${STAMP} — $(human_size "$SIZE_BYTES")"
fi

#--- Retention and success ---------------------------------------------------
# A short local window is a much faster restore path than pulling from Telegram.
STEP="retention"
find "$BACKUP_DIR" -maxdepth 1 -name 'backup-*.tar.gz.age' -mtime "+${RETENTION_DAYS}" -delete
log "local retention: $(find "$BACKUP_DIR" -maxdepth 1 -name 'backup-*.age' | wc -l) archive(s) kept"

STEP="healthchecks ping"
if [[ -n "${HC_PING_URL_BACKUP:-}" ]]; then
  curl -fsS -m 10 -o /dev/null "$HC_PING_URL_BACKUP"
  log "pinged backup healthcheck"
fi

STEP="done"
log "backup completed successfully"
