#!/usr/bin/env bash
# Validate the HAProxy and rsyslog configurations by rendering them with sample
# values and running each daemon's own parser in a container.
#
# This exists because both of these fail in ways that are invisible to shell and
# Go linting: a template that renders to syntactically invalid config, or — worse
# — one that renders to something valid but wrong, such as an unexpanded property
# name silently becoming an empty string.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v docker >/dev/null || { echo "docker not available; skipping config validation"; exit 0; }

WORK="$(mktemp -d)"
# The haproxy container runs as a non-root user and must be able to read the
# rendered config and the map file mounted from here.
chmod 0755 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Mirrors lib.sh render(): only braced variables are substituted, so config
# syntax such as rsyslog's $syslogseverity survives.
render() {
  local src="$1" fmt
  fmt="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$src" | sort -u | tr '\n' ' ')"

  # envsubst replaces a listed-but-unset variable with an empty string rather
  # than leaving ${NAME} behind, so checking the output for leftovers finds
  # nothing. The only reliable check is whether each name is defined at all.
  # "defined but empty" is deliberate for some settings, so test for definition
  # rather than for a value.
  local name missing=()
  for name in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$src" | tr -d '${}' | sort -u); do
    [[ -n "${!name+defined}" ]] || missing+=("$name")
  done
  if (( ${#missing[@]} )); then
    echo "variables referenced by $src but never set:" >&2
    printf '    %s\n' "${missing[@]}" >&2
    return 1
  fi
  envsubst "$fmt" < "$src"
}

export NTFY_DOMAIN=ntfy.example.com MINIFLUX_DOMAIN=rss.example.com
export CD_DOMAIN=watch.example.com HC_DOMAIN=checks.example.com
export SYSLOG_SEVERITY_MAX=4 SYSLOG_TLS_PORT=6514
export ACME_HTTP_PORT=8402
export NTFY_PORT=2586 MINIFLUX_PORT=8080 CD_PORT=5000 HC_PORT=8000

fail=0

echo "==> haproxy"
mkdir -p "$WORK/certs"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/k.pem" -out "$WORK/c.pem" \
  -days 1 -subj "/CN=test" 2>/dev/null
cat "$WORK/c.pem" "$WORK/k.pem" > "$WORK/certs/test.pem"
render vps/haproxy/haproxy.cfg.tmpl > "$WORK/haproxy.cfg"

# Exercise the passthrough mechanism the way it runs in production: the map and
# the generated backends live outside the main config, so a config that parses
# on its own can still be broken once they are loaded alongside it.
mkdir -p "$WORK/conf.d"
printf 'sample.example.com  127.0.0.1:9441\n' > "$WORK/passthrough.conf"
PASSTHROUGH_TABLE="$WORK/passthrough.conf" PASSTHROUGH_MAP="$WORK/sni-passthrough.map" \
HAPROXY_CONF_D="$WORK/conf.d" HAPROXY_MAIN_CFG=/nonexistent \
  ./vps/haproxy/passthrough.sh sync >/dev/null
chmod -R a+rX "$WORK/conf.d" "$WORK/sni-passthrough.map"
# Rewrite absolute paths to the container's mount point. Mounting at a fixed
# path rather than mirroring the host path matters: some docker setups give the
# daemon a private /tmp, and a same-path mount under /tmp is then invisible
# inside the container.
sed -i "s|/etc/haproxy/sni-passthrough.map|/cfg/sni-passthrough.map|g" "$WORK/haproxy.cfg"
sed -i "s|@@ADMIN_UI_USER@@|admin|; s|@@ADMIN_UI_PASSWORD_HASH@@|$(openssl passwd -6 test)|" "$WORK/haproxy.cfg"
sed -i "s|/etc/certs/proxy/combined/|/cfg/certs/|" "$WORK/haproxy.cfg"
# Load conf.d as a second -f, exactly as the systemd unit does.
if docker run --rm -v "$WORK:/cfg:ro" \
     haproxy:lts-alpine haproxy -c -f /cfg/haproxy.cfg -f /cfg/conf.d; then
  echo "    haproxy config OK (with passthrough map and conf.d loaded)"
else
  echo "    haproxy config FAILED"; fail=1
fi

# The generated backend must actually be referenced by the generated map.
if ! grep -q 'be_pt_sample_example_com' "$WORK/conf.d/10-passthrough.cfg" 2>/dev/null \
   || ! grep -q 'be_pt_sample_example_com' "$WORK/sni-passthrough.map" 2>/dev/null; then
  echo "    passthrough map and backends are out of step"; fail=1
else
  echo "    passthrough map/backend names agree"
fi

echo "==> rsyslog"
mkdir -p "$WORK/rsyslog.d" "$WORK/syslogcerts"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/syslogcerts/privkey.pem" \
  -out "$WORK/syslogcerts/fullchain.pem" -days 1 -subj "/CN=localhost" 2>/dev/null
cp "$WORK/syslogcerts/fullchain.pem" "$WORK/syslogcerts/ca.pem"
render vps/syslog/10-local-tls.conf.tmpl  > "$WORK/rsyslog.d/10-local.conf"
render vps/syslog/50-ntfy-alert.conf.tmpl > "$WORK/rsyslog.d/50-alert.conf"
cp vps/syslog/05-template.conf   "$WORK/rsyslog.d/05-template.conf"
cp vps/syslog/20-haproxy-log.conf "$WORK/rsyslog.d/20-haproxy.conf"
printf 'module(load="imuxsock")\n$IncludeConfig /etc/rsyslog.d/*.conf\n' > "$WORK/rsyslog.conf"

# The severity filter must survive rendering. An empty property here would parse
# as `if  <= 4 then`, which is exactly the bug this check was written for.
if ! grep -q 'if \$syslogseverity <= 4 then' "$WORK/rsyslog.d/50-alert.conf"; then
  echo "    severity filter did not render correctly:"
  grep -n 'then {' "$WORK/rsyslog.d/50-alert.conf" | sed 's/^/      /'
  fail=1
fi

if docker run --rm -v "$WORK/rsyslog.conf:/etc/rsyslog.conf:ro" \
     -v "$WORK/rsyslog.d:/etc/rsyslog.d:ro" -v "$WORK/syslogcerts:/etc/certs/syslog:ro" \
     rsyslog-check:local rsyslogd -N1 -f /etc/rsyslog.conf 2>/dev/null; then
  echo "    rsyslog config OK"
else
  echo "    (building an rsyslog image once; this is slow the first time)"
  docker build -q -t rsyslog-check:local - <<'DOCKERFILE' >/dev/null
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq --no-install-recommends rsyslog rsyslog-gnutls \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  if docker run --rm -v "$WORK/rsyslog.conf:/etc/rsyslog.conf:ro" \
       -v "$WORK/rsyslog.d:/etc/rsyslog.d:ro" -v "$WORK/syslogcerts:/etc/certs/syslog:ro" \
       rsyslog-check:local rsyslogd -N1 -f /etc/rsyslog.conf; then
    echo "    rsyslog config OK"
  else
    echo "    rsyslog config FAILED"; fail=1
  fi
fi

echo "==> docker compose"
docker compose -f vps/docker/docker-compose.yml config -q && echo "    compose OK" || { echo "    compose FAILED"; fail=1; }

exit "$fail"
