#!/usr/bin/env bash
# HAProxy: SNI-routed TLS termination, and the security boundary for everything
# reachable from the internet.
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

# Credentials for the admin UIs. changedetection.io has no authentication of its
# own at all, so without this its full admin interface — which drives a browser
# holding your saved logins — is open to anyone who finds the hostname.
ADMIN_UI_USER="$(set_env_var ADMIN_UI_USER admin)"
ADMIN_UI_PASSWORD="$(set_env_var ADMIN_UI_PASSWORD "$(gen_secret 24)")"
ADMIN_UI_PASSWORD_HASH="$(openssl passwd -6 "$ADMIN_UI_PASSWORD")"

TMP_CFG="$(mktemp)"
envsubst < "$REPO_ROOT/vps/haproxy/haproxy.cfg.tmpl" > "$TMP_CFG"

# The crypt hash contains '$' sequences that envsubst would eat, so it is
# substituted afterwards with a literal-safe replacement rather than expanded.
python3 - "$TMP_CFG" "$ADMIN_UI_USER" "$ADMIN_UI_PASSWORD_HASH" <<'PY'
import sys
path, user, pw_hash = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    text = fh.read()
text = text.replace('@@ADMIN_UI_USER@@', user).replace('@@ADMIN_UI_PASSWORD_HASH@@', pw_hash)
with open(path, 'w') as fh:
    fh.write(text)
PY

if grep -q '@@' "$TMP_CFG"; then
  rm -f "$TMP_CFG"
  die "unsubstituted @@placeholders@@ remain in the rendered haproxy config"
fi

# Validate the candidate before it replaces the live config — a bad config here
# takes every service offline at once.
haproxy -c -f "$TMP_CFG" >/dev/null || { rm -f "$TMP_CFG"; die "rendered haproxy config is invalid"; }

if [[ -f /etc/haproxy/haproxy.cfg ]] && cmp -s "$TMP_CFG" /etc/haproxy/haproxy.cfg; then
  log "haproxy config unchanged"
else
  install -o root -g haproxy -m 0640 "$TMP_CFG" /etc/haproxy/haproxy.cfg
  log "wrote /etc/haproxy/haproxy.cfg"
fi
rm -f "$TMP_CFG"

systemctl enable haproxy >/dev/null
if systemctl is-active --quiet haproxy; then
  systemctl reload haproxy
else
  systemctl start haproxy
fi
sleep 1
systemctl is-active --quiet haproxy || die "haproxy failed to start"

log "haproxy ready — routing ${NTFY_DOMAIN}, ${MINIFLUX_DOMAIN}, ${CD_DOMAIN}, ${HC_DOMAIN}"
log ""
log "Admin UI credentials (changedetection + the healthchecks web UI):"
log "  user:     $ADMIN_UI_USER"
log "  password: $ADMIN_UI_PASSWORD"
log "  (also stored in $HUB_ENV)"
log ""
log "Also set a password inside changedetection itself (Settings -> Password) so"
log "it is not relying on the proxy alone."
