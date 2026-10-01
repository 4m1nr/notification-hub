#!/usr/bin/env bash
# Manage TLS passthrough domains.
#
# The routing table lives at /etc/haproxy/passthrough.conf, outside the git
# repository, because the hostnames and internal ports in it are yours. This
# script is the only thing that reads it, and it regenerates three files HAProxy
# consumes:
#
#   /etc/haproxy/sni-passthrough.map              SNI hostname -> backend name
#   /etc/haproxy/conf.d/10-passthrough.cfg        the backend definitions
#   /etc/haproxy/cloudflare-only.passthrough.lst  SNIs only Cloudflare may reach
#
# All are generated; edit passthrough.conf, never them.
set -euo pipefail

TABLE="${PASSTHROUGH_TABLE:-/etc/haproxy/passthrough.conf}"
MAP="${PASSTHROUGH_MAP:-/etc/haproxy/sni-passthrough.map}"
CONF_D="${HAPROXY_CONF_D:-/etc/haproxy/conf.d}"
GENERATED="$CONF_D/10-passthrough.cfg"
MAIN_CFG="${HAPROXY_MAIN_CFG:-/etc/haproxy/haproxy.cfg}"
CF_ONLY_LIST="${CLOUDFLARE_ONLY_PASSTHROUGH_LIST:-/etc/haproxy/cloudflare-only.passthrough.lst}"
CERT_DIR="${HAPROXY_CERT_DIR:-/etc/certs/proxy/combined}"

# Every option the table accepts, in the third and later columns.
VALID_OPTIONS="proxy-protocol proxy-protocol-v1 cloudflare-only terminate"

log()  { printf '[passthrough] %s\n' "$*" >&2; }
die()  { printf '[passthrough] ERROR: %s\n' "$*" >&2; exit 1; }

# Mutating commands need write access to the routing table and HAProxy's config
# directory. Testing for writability rather than for uid 0 keeps the script
# runnable against overridden paths, which is how it is exercised in CI.
require_writable() {
  local d
  for d in "$(dirname "$TABLE")" "$CONF_D" "$(dirname "$MAP")"; do
    [[ -d "$d" ]] || continue
    [[ -w "$d" ]] || die "cannot write to $d (try: sudo $0 $*)"
  done
}

usage() {
  cat >&2 <<EOF
usage: $0 <command> [args]

  list                       Show the configured passthrough domains
  add <domain> <host:port> [option...]
                             Add a domain and apply. '*.x.y' (quoted) routes
                             every a.x.y that has no line of its own. Options:
                               proxy-protocol     send PROXY protocol v2 so the
                                                  backend sees the client IP
                               proxy-protocol-v1  the same, older text format
                               cloudflare-only    drop connections that do not
                                                  come from Cloudflare's ranges
                               terminate          decrypt here and re-encrypt to
                                                  the backend, so the client
                                                  behind Cloudflare is known;
                                                  needs a certificate here
  remove <domain>            Remove a domain and apply
  sync                       Regenerate, validate and reload after editing
                             $TABLE by hand

Adding a domain by hand is just a line in $TABLE followed by '$0 sync'.
EOF
  exit 1
}

# valid_domain accepts a hostname, or a wildcard whose '*' is the whole first
# label. A '*' anywhere else would never match: HAProxy only ever swaps the
# first label of the SNI for '*' when it looks for a wildcard entry.
valid_domain() {
  [[ "${1,,}" =~ ^(\*\.)?([a-z0-9_]([a-z0-9_-]*[a-z0-9_])?\.)+[a-z0-9-]+$ ]]
}

# backend_name turns a hostname into a valid, collision-free HAProxy identifier.
# '*.x.y' becomes be_pt___x_y, which no real hostname can produce because a
# label never starts with '-' or '.'.
backend_name() {
  printf 'be_pt_%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
}

# check_options rejects unknown options and contradictory combinations.
check_options() {
  local where="$1" opt; shift
  for opt in "$@"; do
    [[ " $VALID_OPTIONS " == *" $opt "* ]] \
      || die "unknown option '$opt' for $where — valid: ${VALID_OPTIONS// /, }"
  done
  if has_option proxy-protocol "$@" && has_option proxy-protocol-v1 "$@"; then
    die "$where: proxy-protocol and proxy-protocol-v1 are mutually exclusive"
  fi
}

# has_option <option> <options...> succeeds when the option is in the list.
has_option() {
  local want="$1" opt; shift
  for opt in "$@"; do [[ "$opt" == "$want" ]] && return 0; done
  return 1
}

# has_certificate succeeds when some PEM in CERT_DIR covers the domain by name,
# directly or through a wildcard for its parent (one label only, as in TLS).
# A terminated domain without one would be served another domain's certificate.
has_certificate() {
  local domain="${1,,}" pem
  local wildcard="*.${domain#*.}"
  for pem in "$CERT_DIR"/*.pem; do
    [[ -f "$pem" ]] || continue
    openssl x509 -in "$pem" -noout -ext subjectAltName 2>/dev/null \
      | tr ',' '\n' | sed 's/^ *//' \
      | grep -qixF -e "DNS:$domain" -e "DNS:$wildcard" && return 0
  done
  return 1
}

ensure_table() {
  if [[ ! -f "$TABLE" ]]; then
    install -m 0640 /dev/null "$TABLE"
    printf '# domain                     target\n' > "$TABLE"
    log "created an empty $TABLE"
  fi
}

# read_table emits "domain<TAB>target<TAB>options" for each active line.
read_table() {
  ensure_table
  local domain target options
  while read -r domain target options; do
    [[ -z "${domain:-}" || "${domain:0:1}" == "#" ]] && continue
    valid_domain "$domain" \
      || die "'$domain' in $TABLE is not a hostname or a '*.x.y' wildcard"
    [[ -n "${target:-}" ]] || die "line for '$domain' in $TABLE has no target"
    [[ "$target" == *:* ]] || die "target for '$domain' must be host:port, got '$target'"
    check_options "'$domain' in $TABLE" ${options:-}
    printf '%s\t%s\t%s\n' "${domain,,}" "$target" "${options:-}"
  done < "$TABLE"
}

cmd_list() {
  [[ -f "$TABLE" ]] || { log "no routing table at $TABLE — nothing configured"; return 0; }
  local any=0
  printf '%-32s %-22s %s\n' "DOMAIN" "TARGET" "OPTIONS" >&2
  while IFS=$'\t' read -r domain target options; do
    any=1
    # Flag a target with nothing behind it: the domain would resolve, connect,
    # and then fail in a way that looks like a proxy fault rather than a
    # missing backend service.
    local state=""
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${target##*:}\$" \
      || state="<- nothing listening"
    printf '%-32s %-22s %s %s\n' "$domain" "$target" "${options:-–}" "$state" >&2
  done < <(read_table)
  (( any )) || log "no passthrough domains configured"
}

generate() {
  # Parse the table once in this shell first. read_table also feeds the loop
  # below through a process substitution, where its die() would end only that
  # subshell — and an invalid line would then regenerate an empty map, dropping
  # every route instead of refusing to change anything.
  read_table >/dev/null

  install -d -m 0755 "$CONF_D"

  local tmp_map tmp_cfg tmp_cf tmp_term count=0
  local terminated=()
  tmp_map="$(mktemp)"; tmp_cfg="$(mktemp)"; tmp_cf="$(mktemp)"; tmp_term="$(mktemp)"

  {
    echo "# Generated by passthrough.sh from $TABLE — do not edit."
    echo "# SNI hostname -> backend name"
  } > "$tmp_map"
  {
    echo "# Generated by passthrough.sh from $TABLE — do not edit."
    echo "# TLS passthrough backends. Each keeps its own TLS termination,"
    echo "# except the 'terminate' domains at the end of this file."
    echo
  } > "$tmp_cfg"
  {
    echo "# Generated by passthrough.sh from $TABLE — do not edit."
    echo "# Passthrough SNIs that only Cloudflare's edge may connect to."
  } > "$tmp_cf"

  local domain target options be pp opts
  while IFS=$'\t' read -r domain target options; do
    read -ra opts <<< "$options"
    be="$(backend_name "$domain")"

    has_option cloudflare-only "${opts[@]}" && printf '%s\n' "$domain" >> "$tmp_cf"

    # In TCP mode HAProxy opens a NEW connection to the backend, so the backend
    # sees HAProxy's address as the source. PROXY protocol prepends the original
    # client address to the stream, before the TLS handshake, so the backend can
    # recover it. The backend must be configured to expect it.
    pp=""
    has_option proxy-protocol    "${opts[@]}" && pp=" send-proxy-v2"
    has_option proxy-protocol-v1 "${opts[@]}" && pp=" send-proxy"

    if has_option terminate "${opts[@]}"; then
      # Routed through pt_https_in below rather than straight to the target.
      printf '%s %s\n' "$domain" be_pt_terminate >> "$tmp_map"
      terminated+=("$domain")
      has_certificate "$domain" || {
        log "WARNING: no certificate in $CERT_DIR covers $domain."
        log "  'terminate' decrypts here, so HAProxy needs one: add ${domain#\*.} to"
        log "  /etc/notification-hub/domains.map (format combined, service haproxy),"
        log "  then: sudo /opt/notification-hub/bin/issue-cert.sh '$domain'"
        log "  Until then clients are shown another domain's certificate."
      }
      # The target still terminates its own TLS, so the request is re-encrypted
      # towards it, with the original name as SNI so it picks the right
      # certificate. verify none: the target is this host's own service, and it
      # commonly presents a certificate for the public name, not for its address.
      # WebSockets stay on HTTP/1.1 — most tunnel backends do not accept them
      # over h2 — while everything else, gRPC included, may negotiate h2.
      {
        printf 'backend %s\n' "$be"
        printf '    mode http\n'
        printf '    timeout server 1h\n'
        printf '    timeout tunnel 1h\n'
        printf '    server target %s ssl verify none sni str(%s) alpn h2,http/1.1 ws h1%s\n\n' \
          "$target" "$domain" "$pp"
      } >> "$tmp_term"
    else
      printf '%s %s\n' "$domain" "$be" >> "$tmp_map"
      {
        printf 'backend %s\n' "$be"
        printf '    mode tcp\n'
        # These are tunnels, not requests; the default 60s would cut them.
        printf '    timeout server 1h\n'
        printf '    server target %s%s\n\n' "$target" "$pp"
      } >> "$tmp_cfg"
    fi
    count=$((count + 1))
  done < <(read_table)

  if (( ${#terminated[@]} )); then
    write_terminate_frontend "${terminated[@]}" >> "$tmp_cfg"
    cat "$tmp_term" >> "$tmp_cfg"
  fi

  install -m 0644 "$tmp_map" "$MAP"
  install -m 0644 "$tmp_cfg" "$GENERATED"
  install -m 0644 "$tmp_cf" "$CF_ONLY_LIST"
  rm -f "$tmp_map" "$tmp_cfg" "$tmp_cf" "$tmp_term"
  log "generated $count passthrough backend(s)${terminated[*]:+, ${#terminated[@]} terminated here}"
}

# write_terminate_frontend emits the internal frontend that decrypts the
# 'terminate' domains. Passthrough never sees inside the TLS stream, so behind
# Cloudflare it only ever knows the edge's address; decrypting exposes
# CF-Connecting-IP, and after set-src the PROXY header sent to the target
# carries the real client — the same treatment the hub's own domains get.
write_terminate_frontend() {
  local cf_ips="${CLOUDFLARE_IPS_FILE:-/etc/haproxy/cloudflare-ips.lst}"
  cat <<EOF
#-----------------------------------------------------------------------------
# 'terminate' domains: TLS is decrypted here and re-encrypted to the target.
#-----------------------------------------------------------------------------
backend be_pt_terminate
    mode tcp
    timeout server 1h
    server local_pt_https abns@pt-https send-proxy-v2

frontend pt_https_in
    mode http
    bind abns@pt-https accept-proxy ssl crt $CERT_DIR/ alpn h2,http/1.1
    # Long-lived streams (WebSocket, gRPC) through these tunnels.
    timeout client 1h

    # Which table entry the Host belongs to, resolved the way tls_in resolves
    # the SNI: the exact name first, then '*' in place of the first label.
    acl pt_found var(txn.pt_key) -m found
    http-request set-var(txn.pt_key) hdr(host),field(1,:),lower if { hdr(host),field(1,:),lower,map($MAP) -m found }
    http-request set-var(txn.pt_key) hdr(host),field(1,:),lower,regsub(^[^.]+[.],*.) if !pt_found { hdr(host),field(1,:),lower,regsub(^[^.]+[.],*.),map($MAP) -m found }

    # A direct client may present an allowed SNI and then ask for a
    # Cloudflare-only Host inside it. Checked before set-src replaces src.
    acl from_cloudflare src -f $cf_ips
    acl cf_only_host    var(txn.pt_key) -m str -f $CF_ONLY_LIST
    http-request silent-drop if cf_only_host !from_cloudflare

    # CF-Connecting-IP is trusted only from Cloudflare's ranges, exactly as on
    # the hub's frontend; from anyone else it is deleted, so it cannot be forged.
    acl has_cf_ip req.hdr(CF-Connecting-IP) -m found
    http-request set-src req.hdr(CF-Connecting-IP) if from_cloudflare has_cf_ip
    http-request del-header CF-Connecting-IP unless from_cloudflare
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-For %[src]

    acl known_host var(txn.pt_key) -m str $*
    acl acme_challenge path_beg /.well-known/acme-challenge/
    http-request deny deny_status 421 unless known_host
    use_backend be_acme if acme_challenge
EOF
  local domain
  for domain in "$@"; do
    printf '    use_backend %s if { var(txn.pt_key) -m str %s }\n' \
      "$(backend_name "$domain")" "$domain"
  done
  echo
}

validate_and_reload() {
  [[ -f "$MAIN_CFG" ]] || { log "$MAIN_CFG not present yet; generated files only"; return 0; }

  # Validate exactly the way the service starts, both config sources included.
  if ! haproxy -c -f "$MAIN_CFG" -f "$CONF_D" >/dev/null; then
    die "haproxy rejected the resulting configuration; nothing was reloaded"
  fi
  log "configuration valid"

  if systemctl is-active --quiet haproxy; then
    # reload, not restart: in-flight connections, including the passthrough
    # sessions this script just changed, are handed to the new process.
    systemctl reload haproxy
    log "haproxy reloaded"
  else
    log "haproxy is not running; start it when ready"
  fi
}

cmd_sync() { generate; validate_and_reload; }

cmd_add() {
  local domain="${1:-}" target="${2:-}"
  [[ -n "$domain" && -n "$target" ]] || die "usage: $0 add <domain> <host:port> [option...]"
  [[ "$target" == *:* ]] || die "target must be host:port, e.g. 127.0.0.1:441"
  valid_domain "$domain" || die "'$domain' is not a hostname or a '*.x.y' wildcard"
  domain="${domain,,}"
  shift 2
  check_options "'$domain'" "$@"
  ensure_table

  if read_table | cut -f1 | grep -qxF "$domain"; then
    die "'$domain' is already in $TABLE — remove it first, or edit the file"
  fi
  printf '%-28s %-22s %s\n' "$domain" "$target" "$*" >> "$TABLE"
  log "added $domain -> $target${*:+ ($*)}"
  if has_option proxy-protocol "$@" || has_option proxy-protocol-v1 "$@"; then
    log ""
    log "PROXY protocol is now sent to this backend. The backend MUST be"
    log "configured to accept it, or every connection will fail — and once it"
    log "does, connecting to it directly (bypassing HAProxy) will also fail."
  fi
  if has_option cloudflare-only "$@"; then
    log ""
    log "Only Cloudflare's edge may now connect to $domain; everyone else is"
    log "silently dropped. Its DNS record must be proxied (orange cloud)."
  fi
  cmd_sync
}

cmd_remove() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || die "usage: $0 remove <domain>"
  ensure_table
  domain="${domain,,}"
  read_table | cut -f1 | grep -qxF "$domain" || die "'$domain' is not in $TABLE"

  local tmp; tmp="$(mktemp)"
  awk -v d="$domain" 'tolower($1) != d' "$TABLE" > "$tmp"
  install -m 0640 "$tmp" "$TABLE"
  rm -f "$tmp"
  log "removed $domain"
  cmd_sync
}

case "${1:-}" in
  list)   shift; cmd_list "$@" ;;
  add)    shift; require_writable add "$@";    cmd_add "$@" ;;
  remove) shift; require_writable remove "$@"; cmd_remove "$@" ;;
  sync)   shift; require_writable sync;        cmd_sync "$@" ;;
  *) usage ;;
esac
