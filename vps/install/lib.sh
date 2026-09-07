#!/usr/bin/env bash
# Shared helpers for every installer in this repo (VPS and office PC alike).
# Sourced, never executed directly.

set -euo pipefail

HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"
HUB_PREFIX="${HUB_PREFIX:-/opt/notification-hub}"
HUB_STATE="${HUB_STATE:-/var/lib/notification-hub}"

# Repo root, derived from this file's location so scripts work from any cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_c_reset=$'\033[0m'; _c_blue=$'\033[34m'; _c_yellow=$'\033[33m'; _c_red=$'\033[31m'

log()  { printf '%s==>%s %s\n' "$_c_blue" "$_c_reset" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "must run as root (try: sudo $0)"
}

# load_env sources the hub environment file and exports everything in it.
load_env() {
  [[ -f "$HUB_ENV" ]] || die "$HUB_ENV not found — copy .env.example to it and fill it in"
  set -a
  # shellcheck disable=SC1090
  source "$HUB_ENV"
  set +a
}

# require_vars fails with the full list of what's missing, rather than one per run.
require_vars() {
  local missing=()
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} )); then
    die "missing in $HUB_ENV: ${missing[*]}"
  fi
}

# apt_ensure installs only the packages that are not already present, so re-runs
# are fast and quiet.
apt_ensure() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed" || missing+=("$pkg")
  done
  if (( ${#missing[@]} )); then
    log "installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}

# ensure_sysuser creates a locked system account with no login shell.
ensure_sysuser() {
  local user="$1" home="${2:-/nonexistent}"
  if ! id -u "$user" >/dev/null 2>&1; then
    log "creating system user $user"
    useradd --system --shell /usr/sbin/nologin --home-dir "$home" "$user"
  fi
}

# ensure_dir makes a directory with an explicit mode and owner.
ensure_dir() {
  local path="$1" mode="$2" owner="$3"
  mkdir -p "$path"
  chmod "$mode" "$path"
  chown "$owner" "$path"
}

# render expands ${VAR} references in a template and installs the result, but only
# writes when the content actually changed — so a re-run doesn't churn mtimes or
# trigger spurious reloads.
#
# Only variables written with braces are substituted. Bare $NAME is left alone,
# because config formats we template have their own $-syntax that must survive:
# rsyslog's $syslogseverity, for instance, would otherwise be expanded to an
# empty string by envsubst and silently destroy the filter rule.
render() {
  local src="$1" dest="$2" mode="${3:-0644}" owner="${4:-root:root}"
  [[ -f "$src" ]] || die "template not found: $src"

  # Build the explicit substitution list from the template itself.
  local shell_format
  shell_format="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$src" | sort -u | tr '\n' ' ')"

  local tmp
  tmp="$(mktemp)"
  envsubst "$shell_format" < "$src" > "$tmp"

  # A leftover ${...} means a variable was referenced but never set.
  if grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$tmp"; then
    warn "unset variables in $src:"
    grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$tmp" | sort -u | sed 's/^/    /' >&2
    rm -f "$tmp"
    die "refusing to install a template with unresolved variables"
  fi

  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    chmod "$mode" "$dest"; chown "$owner" "$dest"
    return 1   # unchanged
  fi
  install -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  log "wrote $dest"
  return 0     # changed
}

# install_file copies a non-template file with the same change detection.
install_file() {
  local src="$1" dest="$2" mode="${3:-0644}" owner="${4:-root:root}"
  [[ -f "$src" ]] || die "file not found: $src"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    chmod "$mode" "$dest"; chown "$owner" "$dest"
    return 1
  fi
  install -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$src" "$dest"
  log "wrote $dest"
  return 0
}

# install_unit installs a systemd unit (rendering ${VAR} references) and reloads
# the daemon once at the end of the calling script via systemd_reload.
install_unit() {
  local src="$1"
  local name; name="$(basename "$src")"
  name="${name%.tmpl}"
  if render "$src" "/etc/systemd/system/$name" 0644 root:root; then
    SYSTEMD_DIRTY=1
  fi
}

systemd_reload() {
  if [[ "${SYSTEMD_DIRTY:-0}" == "1" ]]; then
    log "reloading systemd"
    systemctl daemon-reload
    SYSTEMD_DIRTY=0
  fi
}

# enable_now enables and starts units, restarting any that are already running so
# new config takes effect.
enable_now() {
  local unit
  for unit in "$@"; do
    systemctl enable "$unit" >/dev/null
    if systemctl is-active --quiet "$unit"; then
      systemctl restart "$unit"
    else
      systemctl start "$unit"
    fi
    log "$unit is $(systemctl is-active "$unit")"
  done
}

# go_build_install compiles one command from this repo into the shared bin
# directory. Binaries are static so they have no runtime dependencies.
go_build_install() {
  local cmd="$1"
  command -v go >/dev/null || die "go toolchain not found; run 10-packages.sh first"
  ensure_dir "$HUB_PREFIX/bin" 0755 root:root
  log "building $cmd"
  ( cd "$REPO_ROOT" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
      -o "$HUB_PREFIX/bin/$cmd" "./cmd/$cmd" )
  chmod 0755 "$HUB_PREFIX/bin/$cmd"
}

# gen_secret prints a URL-safe random string, used for generated passwords.
gen_secret() {
  local bytes="${1:-32}"
  openssl rand -base64 "$bytes" | tr -d '\n=+/' | cut -c1-"$((bytes))"
}

# set_env_var appends KEY=value to the hub env file if the key is not already
# present, and echoes the effective value. Used for generated credentials that
# must survive re-runs.
set_env_var() {
  local key="$1" value="$2"
  ensure_dir "$(dirname "$HUB_ENV")" 0750 root:root
  touch "$HUB_ENV"; chmod 0600 "$HUB_ENV"
  if grep -qE "^${key}=" "$HUB_ENV"; then
    grep -E "^${key}=" "$HUB_ENV" | tail -n1 | cut -d= -f2- | tr -d '"'
    return 0
  fi
  printf '%s="%s"\n' "$key" "$value" >> "$HUB_ENV"
  log "generated $key"
  printf '%s' "$value"
}
