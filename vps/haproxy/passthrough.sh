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
#   /etc/haproxy/redirect-hosts.lst               hosts with HTTP redirects
#
# It also reads /etc/haproxy/redirects.conf, the HTTP redirect table
# ('redirect' commands below). All are generated; edit the two tables, never
# the generated files.
set -euo pipefail

TABLE="${PASSTHROUGH_TABLE:-/etc/haproxy/passthrough.conf}"
MAP="${PASSTHROUGH_MAP:-/etc/haproxy/sni-passthrough.map}"
CONF_D="${HAPROXY_CONF_D:-/etc/haproxy/conf.d}"
GENERATED="$CONF_D/10-passthrough.cfg"
MAIN_CFG="${HAPROXY_MAIN_CFG:-/etc/haproxy/haproxy.cfg}"
CF_ONLY_LIST="${CLOUDFLARE_ONLY_PASSTHROUGH_LIST:-/etc/haproxy/cloudflare-only.passthrough.lst}"
CERT_DIR="${HAPROXY_CERT_DIR:-/etc/certs/proxy/combined}"
REDIRECT_TABLE="${REDIRECT_TABLE:-/etc/haproxy/redirects.conf}"
REDIRECT_HOSTS_LIST="${REDIRECT_HOSTS_LIST:-/etc/haproxy/redirect-hosts.lst}"
HUB_ENV="${HUB_ENV:-/etc/notification-hub/hub.env}"

# Redirect status codes the redirect table accepts; 302 when none is given.
VALID_REDIRECT_CODES="301 302 303 307 308"

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
                             $TABLE or $REDIRECT_TABLE by hand

  redirect list              Show the HTTP redirects
  redirect add <host[/path]> <http(s)://dest[/path]> [code] [drop-path]
                             Redirect a host, or every path under a prefix of
                             it, keeping the rest of the path and the query:
                               x.y/sub -> https://a.b.c/sub sends
                               x.y/sub/p?q=1 to https://a.b.c/sub/p?q=1
                             code: 301 302 303 307 308 (default 302)
                             drop-path: always send to the destination as is
  redirect remove <host[/path]>
                             Remove a redirect and apply

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

# Redirect fields travel '|'-separated, never tab-separated: read collapses
# consecutive tabs, so an empty path (a whole-host redirect) would shift every
# field after it. Validation keeps '|' out of all of them.
#
# split_source prints "host|path" for a redirect source: the host
# lowercased, the path with trailing slashes removed ("" for the whole host).
split_source() {
  local src="$1" host path=""
  host="${src%%/*}"
  [[ "$src" == */* ]] && path="/${src#*/}"
  while [[ "$path" == */ ]]; do path="${path%/}"; done
  printf '%s|%s\n' "${host,,}" "$path"
}

# check_redirect validates one redirect and dies with its location on error.
# Paths are limited to unreserved URL characters, which is also what keeps
# them safe to place in the generated regex and in HAProxy's quoted strings.
check_redirect() {
  local where="$1" source="$2" dest="$3"; shift 3
  local host path opt code=""
  [[ "$source" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._~/-]*)?$ ]] \
    || die "$where: source '$source' must be host or host/path (letters, digits, . _ ~ - /)"
  IFS='|' read -r host path < <(split_source "$source")
  valid_domain "$host" && [[ "$host" != \** ]] \
    || die "$where: '$host' is not a hostname (redirect sources cannot be wildcards)"
  [[ "$dest" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] \
    || die "$where: destination '$dest' must be http(s)://host[:port][/path] (letters, digits, . _ ~ - /)"
  for opt in "$@"; do
    if [[ " $VALID_REDIRECT_CODES " == *" $opt "* ]]; then
      [[ -z "$code" ]] || die "$where: more than one status code"
      code="$opt"
    elif [[ "$opt" != drop-path ]]; then
      die "$where: unknown redirect option '$opt' — valid: ${VALID_REDIRECT_CODES// /, }, drop-path"
    fi
  done

  # A destination under its own source redirects to itself forever.
  local rest="${dest#*://}" dhost dpath=""
  dhost="${rest%%/*}"; dhost="${dhost%%:*}"
  [[ "$rest" == */* ]] && dpath="/${rest#*/}"
  if [[ "${dhost,,}" == "$host" ]] \
     && { [[ -z "$path" ]] || [[ "$dpath" == "$path" || "$dpath" == "$path"/* ]]; }; then
    die "$where: $dest is under $source itself, which would redirect forever"
  fi
}

# read_redirects emits "host|path|dest|code|drop" for each
# active line, longest path first within a host so the most specific prefix
# wins whatever the order of the file.
read_redirects() {
  [[ -f "$REDIRECT_TABLE" ]] || return 0
  local source dest options host path opt code drop
  while read -r source dest options; do
    [[ -z "${source:-}" || "${source:0:1}" == "#" ]] && continue
    [[ -n "${dest:-}" ]] || die "line for '$source' in $REDIRECT_TABLE has no destination"
    # shellcheck disable=SC2086
    check_redirect "'$source' in $REDIRECT_TABLE" "$source" "$dest" ${options:-}
    IFS='|' read -r host path < <(split_source "$source")
    code=302 drop=0
    for opt in ${options:-}; do
      case "$opt" in drop-path) drop=1 ;; *) code="$opt" ;; esac
    done
    printf '%s|%s|%s|%s|%s|%s\n' "${#path}" "$host" "$path" "$dest" "$code" "$drop"
  done < "$REDIRECT_TABLE" | sort -t'|' -k2,2 -k1,1nr | cut -d'|' -f2-
}

# hub_domains prints the hub's own domains, which a redirect may not take over:
# they are TLS-terminated by the main frontend, never by pt_https_in.
hub_domains() {
  [[ -r "$HUB_ENV" ]] || return 0
  (
    set +u
    # shellcheck disable=SC1090
    source "$HUB_ENV" >/dev/null 2>&1
    printf '%s\n' "${NTFY_DOMAIN:-}" "${MINIFLUX_DOMAIN:-}" "${CD_DOMAIN:-}" "${HC_DOMAIN:-}"
  ) | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true
}

# redirect_rules emits the http-request rules for every redirect, at the given
# indent. Used in the decrypting frontend and in the port-80 backend alike.
redirect_rules() {
  local host path dest code drop host_acl location
  while IFS='|' read -r host path dest code drop; do
    host_acl="{ hdr(host),field(1,:),lower -m str $host }"
    if (( drop )); then
      location="$dest"
    elif [[ -z "$path" ]]; then
      location="${dest%/}%[pathq]"
    else
      # Strip the matched prefix and append what follows, query included.
      location="${dest%/}%[pathq,regsub(^${path//./[.]},)]"
    fi
    if [[ -z "$path" ]]; then
      printf '    http-request redirect location "%s" code %s if %s\n' "$location" "$code" "$host_acl"
    else
      printf '    http-request redirect location "%s" code %s if %s { path -m str %s } || %s { path_beg %s/ }\n' \
        "$location" "$code" "$host_acl" "$path" "$host_acl" "$path"
    fi
  done
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
  read_redirects >/dev/null

  install -d -m 0755 "$CONF_D"

  local tmp_map tmp_cfg tmp_cf tmp_term tmp_rd count=0
  local terminated=() redirect_only=()
  tmp_map="$(mktemp)"; tmp_cfg="$(mktemp)"; tmp_cf="$(mktemp)"; tmp_term="$(mktemp)"
  tmp_rd="$(mktemp)"
  read_redirects > "$tmp_rd"

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

  # --- HTTP redirects ---
  # A path is only visible once TLS is decrypted, so every redirect host must
  # reach pt_https_in: through its own 'terminate' line or a 'terminate'
  # wildcard over it, or else through an entry added here for it alone.
  local hubs rhost wild wild_opts exact_opts n_redirects
  hubs="$(hub_domains)"
  n_redirects="$(grep -c . "$tmp_rd" || true)"
  {
    echo "# Generated by passthrough.sh from $REDIRECT_TABLE — do not edit."
    echo "# Hosts with HTTP redirects; port 80 sends them to be_http_redirects."
    cut -d'|' -f1 "$tmp_rd" | sort -u
  } > "$tmp_rd.hosts"

  while read -r rhost; do
    [[ -n "$rhost" ]] || continue
    grep -qxF "$rhost" <<< "$hubs" \
      && die "redirect source $rhost is one of the hub's own domains; redirects cannot take those over"
    exact_opts="$(read_table | awk -F'\t' -v d="$rhost" '$1 == d {print $3 "|"}')"
    wild="*.${rhost#*.}"
    wild_opts="$(read_table | awk -F'\t' -v d="$wild" '$1 == d {print $3 "|"}')"
    if [[ -n "$exact_opts" ]]; then
      # shellcheck disable=SC2086
      has_option terminate ${exact_opts%|} \
        || die "redirect source $rhost is a plain passthrough domain in $TABLE; its TLS is never
  decrypted here, so no path can be seen. Add the 'terminate' option to its line, or remove the line."
      continue
    fi
    # shellcheck disable=SC2086
    if [[ -n "$wild_opts" ]] && has_option terminate ${wild_opts%|}; then
      continue    # decrypted already; other paths keep going to the wildcard's target
    fi
    [[ -n "$wild_opts" ]] && log "NOTE: $rhost now ends here instead of at $wild's target; paths without a redirect get 404"
    printf '%s %s\n' "$rhost" be_pt_terminate >> "$tmp_map"
    redirect_only+=("$rhost")
    has_certificate "$rhost" || {
      log "WARNING: no certificate in $CERT_DIR covers $rhost."
      log "  HTTPS redirects are answered here, so HAProxy needs one: add $rhost to"
      log "  /etc/notification-hub/domains.map (format combined, service haproxy),"
      log "  then: sudo /opt/notification-hub/bin/issue-cert.sh $rhost"
    }
  done < <(sed '/^#/d' "$tmp_rd.hosts")

  if (( ${#terminated[@]} + ${#redirect_only[@]} )); then
    write_terminate_frontend "$tmp_rd" "${#terminated[@]}" "${terminated[@]}" "${redirect_only[@]}" >> "$tmp_cfg"
    cat "$tmp_term" >> "$tmp_cfg"
  fi

  # Port 80 hands every redirect host to this backend, so a plain-HTTP request
  # goes straight to its destination instead of first being sent to HTTPS on
  # the same host. Paths without a redirect still get that HTTPS upgrade. It is
  # always generated: haproxy.cfg refers to it even when the table is empty.
  {
    echo "#-----------------------------------------------------------------------------"
    echo "# HTTP redirects on port 80, from $REDIRECT_TABLE."
    echo "#-----------------------------------------------------------------------------"
    echo "backend be_http_redirects"
    echo "    mode http"
    redirect_rules < "$tmp_rd"
    echo "    http-request redirect scheme https code 301"
    echo
  } >> "$tmp_cfg"

  install -m 0644 "$tmp_map" "$MAP"
  install -m 0644 "$tmp_cfg" "$GENERATED"
  install -m 0644 "$tmp_cf" "$CF_ONLY_LIST"
  install -m 0644 "$tmp_rd.hosts" "$REDIRECT_HOSTS_LIST"
  rm -f "$tmp_map" "$tmp_cfg" "$tmp_cf" "$tmp_term" "$tmp_rd" "$tmp_rd.hosts"
  log "generated $count passthrough backend(s)${terminated[*]:+, ${#terminated[@]} terminated here}, $n_redirects redirect(s)"
}

# write_terminate_frontend emits the internal frontend that decrypts the
# 'terminate' domains. Passthrough never sees inside the TLS stream, so behind
# Cloudflare it only ever knows the edge's address; decrypting exposes
# CF-Connecting-IP, and after set-src the PROXY header sent to the target
# carries the real client — the same treatment the hub's own domains get.
# Redirects are answered here too, for the same reason: only decrypted traffic
# has a path.
#
#   write_terminate_frontend <redirects-file> <n-terminated> <terminated...> <redirect-only...>
write_terminate_frontend() {
  local cf_ips="${CLOUDFLARE_IPS_FILE:-/etc/haproxy/cloudflare-ips.lst}"
  local redirects="$1" n_term="$2"; shift 2
  local terminated=("${@:1:n_term}") redirect_only=("${@:n_term+1}")
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
  if [[ -s "$redirects" ]]; then
    echo
    echo "    # HTTP redirects, from $REDIRECT_TABLE. Longest prefix first per host."
    redirect_rules < "$redirects"
  fi
  if (( ${#redirect_only[@]} )); then
    echo "    # Hosts that exist here only for their redirects."
    printf '    http-request return status 404 content-type text/plain string "Not found" if { var(txn.pt_key) -m str %s }\n' \
      "${redirect_only[*]}"
  fi
  local domain
  for domain in "${terminated[@]}"; do
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

# sync_or_restore applies a table that was just edited, and puts the table back
# as it was if that fails, so a rejected line never stays behind to block every
# later sync.
sync_or_restore() {
  local table="$1" backup="$2"
  if ( cmd_sync ); then
    rm -f "$backup"
    return 0
  fi
  install -m 0640 "$backup" "$table"
  rm -f "$backup"
  ( generate ) >/dev/null 2>&1 || true
  die "change rejected; $table is back as it was"
}

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
  local backup; backup="$(mktemp)"; cp -p "$TABLE" "$backup"
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
  sync_or_restore "$TABLE" "$backup"
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

ensure_redirect_table() {
  if [[ ! -f "$REDIRECT_TABLE" ]]; then
    install -m 0640 /dev/null "$REDIRECT_TABLE"
    printf '# source (host[/path])        destination                   options\n' > "$REDIRECT_TABLE"
    log "created an empty $REDIRECT_TABLE"
  fi
}

cmd_redirect() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)
      [[ -s "$REDIRECT_TABLE" ]] || { log "no redirects configured"; return 0; }
      printf '%-36s %-40s %s\n' SOURCE DESTINATION OPTIONS >&2
      local host path dest code drop
      while IFS='|' read -r host path dest code drop; do
        (( drop )) && code+=" drop-path"
        printf '%-36s %-40s %s\n' "$host$path" "$dest" "$code" >&2
      done < <(read_redirects)
      ;;
    add)
      local source="${1:-}" dest="${2:-}"
      [[ -n "$source" && -n "$dest" ]] || die "usage: $0 redirect add <host[/path]> <http(s)://dest[/path]> [code] [drop-path]"
      shift 2
      check_redirect "'$source'" "$source" "$dest" "$@"
      ensure_redirect_table
      local key; key="$(split_source "$source" | tr -d '|')"
      if read_redirects | awk -F'|' '{print $1 $2}' | grep -qxF "$key"; then
        die "$key already redirects — remove it first, or edit $REDIRECT_TABLE"
      fi
      local backup; backup="$(mktemp)"; cp -p "$REDIRECT_TABLE" "$backup"
      printf '%-30s %-40s %s\n' "$key" "$dest" "$*" >> "$REDIRECT_TABLE"
      log "added redirect $key -> $dest${*:+ ($*)}"
      sync_or_restore "$REDIRECT_TABLE" "$backup"
      ;;
    remove)
      local source="${1:-}"
      [[ -n "$source" ]] || die "usage: $0 redirect remove <host[/path]>"
      local key; key="$(split_source "$source" | tr -d '|')"
      read_redirects | awk -F'|' '{print $1 $2}' | grep -qxF "$key" || die "no redirect for $key"
      local tmp line src
      tmp="$(mktemp)"
      while IFS= read -r line; do
        src="$(awk '{print $1}' <<< "$line")"
        if [[ -n "$src" && "${src:0:1}" != "#" && "$(split_source "$src" | tr -d '|')" == "$key" ]]; then
          continue
        fi
        printf '%s\n' "$line" >> "$tmp"
      done < "$REDIRECT_TABLE"
      install -m 0640 "$tmp" "$REDIRECT_TABLE"
      rm -f "$tmp"
      log "removed redirect $key"
      cmd_sync
      ;;
    *) usage ;;
  esac
}

case "${1:-}" in
  list)   shift; cmd_list "$@" ;;
  redirect)
    shift
    [[ "${1:-}" == list ]] || require_writable redirect "$@"
    cmd_redirect "$@" ;;
  add)    shift; require_writable add "$@";    cmd_add "$@" ;;
  remove) shift; require_writable remove "$@"; cmd_remove "$@" ;;
  sync)   shift; require_writable sync;        cmd_sync "$@" ;;
  *) usage ;;
esac
