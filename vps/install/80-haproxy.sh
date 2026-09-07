#!/usr/bin/env bash
# HAProxy: SNI-routed TLS termination in front of everything.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars NTFY_DOMAIN MINIFLUX_DOMAIN CD_DOMAIN HC_DOMAIN

apt_ensure haproxy

ensure_dir /etc/certs/proxy/combined 0750 root:haproxy

# HAProxy refuses to start with an empty crt directory, which is the state on a
# first install before any certificate has been issued.
if ! compgen -G "/etc/certs/proxy/combined/*.pem" >/dev/null; then
  die "no certificates in /etc/certs/proxy/combined/
  Issue them first, then distribute:
    certbot certonly --standalone -d ${NTFY_DOMAIN} --email \${ACME_EMAIL} --agree-tos
    $HUB_PREFIX/bin/distribute-certs.sh"
fi

render "$REPO_ROOT/vps/haproxy/haproxy.cfg.tmpl" /etc/haproxy/haproxy.cfg 0644 root:root || true

# Validate before touching the running process — a bad config here takes every
# service offline at once.
haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null || die "haproxy config is invalid"

systemctl enable haproxy >/dev/null
if systemctl is-active --quiet haproxy; then
  systemctl reload haproxy
else
  systemctl start haproxy
fi
systemctl is-active --quiet haproxy || die "haproxy failed to start"

log "haproxy ready — routing ${NTFY_DOMAIN}, ${MINIFLUX_DOMAIN}, ${CD_DOMAIN}, ${HC_DOMAIN}"
