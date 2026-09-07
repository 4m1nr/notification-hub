#!/usr/bin/env bash
# Base packages: everything the rest of the installers assume is present.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

log "updating apt index"
apt-get update -qq

apt_ensure \
  ca-certificates curl gnupg gettext-base openssl \
  postgresql postgresql-client \
  haproxy \
  rsyslog rsyslog-gnutls \
  certbot \
  age \
  socat \
  jq

# Go toolchain — used to build our four services from source on the box, so the
# repo never has to ship binaries.
if ! command -v go >/dev/null; then
  apt_ensure golang-go
fi
command -v go >/dev/null || die "go toolchain unavailable; install Go 1.25+ manually"

# Docker, for the two services we deliberately keep containerised
# (changedetection.io + its Playwright browser, and healthchecks.io).
if ! command -v docker >/dev/null; then
  log "installing docker engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF
  apt-get update -qq
  apt_ensure docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker >/dev/null

ensure_dir /etc/notification-hub 0750 root:root
ensure_dir "$HUB_PREFIX/bin" 0755 root:root
ensure_dir "$HUB_STATE" 0750 root:root
ensure_dir "$HUB_STATE/pending-restart" 0750 root:root

log "base packages ready"
