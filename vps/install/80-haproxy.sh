#!/usr/bin/env bash
# HAProxy: SNI-routed TLS termination, and the security boundary for everything
# reachable from the internet.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
load_env
require_vars NTFY_DOMAIN MINIFLUX_DOMAIN CD_DOMAIN HC_DOMAIN

apt_ensure haproxy

# Marker identifying a config this project generated, so an existing one written
# by hand is recognisable and gets backed up rather than silently replaced.
CONFIG_MARKER="Rendered from vps/haproxy/haproxy.cfg.tmpl"

ensure_dir /etc/certs/proxy/combined 0750 root:haproxy

# ---------------------------------------------------------------------------
# TLS passthrough: routing table and generated files.
#
# The table lives outside the repository because the hostnames and internal
# ports in it belong to this host, not to this project. Both generated files
# must exist before HAProxy starts — it refuses to start if the map named in
# its config is missing, even when empty.
# ---------------------------------------------------------------------------
install_file "$REPO_ROOT/vps/haproxy/passthrough.sh" "$HUB_PREFIX/bin/passthrough.sh" 0750 root:root || true
ensure_dir /etc/haproxy/conf.d 0755 root:root

if [[ ! -f /etc/haproxy/passthrough.conf ]]; then
  install_file "$REPO_ROOT/vps/haproxy/passthrough.conf.example" \
    /etc/haproxy/passthrough.conf 0640 root:root || true
  log "seeded /etc/haproxy/passthrough.conf (no domains configured yet)"
fi
[[ -f /etc/haproxy/sni-passthrough.map ]] || install -m 0644 /dev/null /etc/haproxy/sni-passthrough.map

# Regenerate from the table. Done before the main config is validated, so the
# check below covers the passthrough backends too.
PASSTHROUGH_TABLE=/etc/haproxy/passthrough.conf HAPROXY_MAIN_CFG=/nonexistent \
  "$HUB_PREFIX/bin/passthrough.sh" sync

# ---------------------------------------------------------------------------
# Load conf.d alongside the main config.
#
# HAProxy has no include directive, but accepts repeated -f, and a directory
# argument loads every file in it. The distro's unit builds its command line
# from EXTRAOPTS, so append rather than replace — otherwise a future package
# update that adds an option there would be silently dropped.
# ---------------------------------------------------------------------------
CURRENT_EXTRAOPTS="$(systemctl show haproxy -p Environment --value 2>/dev/null \
  | tr ' ' '\n' | sed -n 's/^EXTRAOPTS=//p' | head -n1)"
CURRENT_EXTRAOPTS="${CURRENT_EXTRAOPTS:--S /run/haproxy-master.sock}"

if [[ "$CURRENT_EXTRAOPTS" != *"-f /etc/haproxy/conf.d"* ]]; then
  ensure_dir /etc/systemd/system/haproxy.service.d 0755 root:root
  cat > /etc/systemd/system/haproxy.service.d/notification-hub-confd.conf <<EOF
# Load /etc/haproxy/conf.d in addition to the main config, so TLS passthrough
# backends can live outside the generated haproxy.cfg.
[Service]
Environment="EXTRAOPTS=$CURRENT_EXTRAOPTS -f /etc/haproxy/conf.d"
EOF
  SYSTEMD_DIRTY=1
  systemd_reload
  log "haproxy will now also load /etc/haproxy/conf.d"
fi

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
haproxy -c -f "$TMP_CFG" -f /etc/haproxy/conf.d >/dev/null \
  || { rm -f "$TMP_CFG"; die "rendered haproxy config is invalid"; }

if [[ -f /etc/haproxy/haproxy.cfg ]] && cmp -s "$TMP_CFG" /etc/haproxy/haproxy.cfg; then
  log "haproxy config unchanged"
else
  # This host may already have been serving other things through HAProxy. Never
  # replace a config that this project did not write without keeping a copy.
  if [[ -f /etc/haproxy/haproxy.cfg ]] && ! grep -q "$CONFIG_MARKER" /etc/haproxy/haproxy.cfg; then
    BACKUP="/etc/haproxy/haproxy.cfg.pre-notification-hub.$(date +%Y%m%d%H%M%S)"
    cp -a /etc/haproxy/haproxy.cfg "$BACKUP"
    warn "an existing, unmanaged haproxy.cfg was found and backed up to:"
    warn "  $BACKUP"
    warn "if it routed anything this config does not, merge those rules into"
    warn "vps/haproxy/haproxy.cfg.tmpl and re-run — do not edit the live file,"
    warn "it is regenerated on every run"
  fi
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
log ""
log "TLS passthrough for other services on this host:"
log "  $HUB_PREFIX/bin/passthrough.sh add <domain> <host:port>"
log "  $HUB_PREFIX/bin/passthrough.sh list"
log "(the table is /etc/haproxy/passthrough.conf and is not tracked in git)"
