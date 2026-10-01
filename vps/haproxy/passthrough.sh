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
                               port=N[,N...]      listen on these ports instead
                                                  of 443 (see below)
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
                             port=N[,N...]: HTTPS ports instead of 443
  redirect remove <host[/path]>
                             Remove a redirect and apply

Ports: 443 is the default and pairs with plain HTTP on 80. Any other port
gets a listener of its own, which serves only the entries naming it: TLS for
them is routed as on 443, plain HTTP for them is redirected to
https://<host>:<port>, and anything else on that port is silently dropped.

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

# check_ports validates the value of a port= option: distinct ports, no
# leading zeros (bash would read them as octal), and never 80, which is the
# plain-HTTP side of 443.
check_ports() {
  local where="$1" list="$2" p seen=" "
  [[ "$list" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] \
    || die "$where: port= takes a comma-separated list of ports, got '$list'"
  for p in ${list//,/ }; do
    (( p <= 65535 )) || die "$where: port $p is out of range"
    (( p != 80 )) || die "$where: port 80 is the plain-HTTP side of 443; list 443 instead"
    [[ "$seen" != *" $p "* ]] || die "$where: port $p is listed twice"
    seen+="$p "
  done
}

# ports_of prints an entry's ports, comma-separated: its port= option, or 443.
ports_of() {
  local opt
  for opt in "$@"; do
    [[ "$opt" == port=* ]] && { printf '%s\n' "${opt#port=}"; return 0; }
  done
  printf '443\n'
}

# has_port <ports> <port> succeeds when the comma-separated list contains it.
has_port() { [[ ",$1," == *",$2,"* ]]; }

# ports_and / ports_minus print the intersection / difference of two
# comma-separated lists, comma-separated ("" when empty).
ports_and() {
  local p out=()
  for p in ${1//,/ }; do has_port "$2" "$p" && out+=("$p"); done
  local IFS=,; printf '%s\n' "${out[*]}"
}
ports_minus() {
  local p out=()
  for p in ${1//,/ }; do has_port "$2" "$p" || out+=("$p"); done
  local IFS=,; printf '%s\n' "${out[*]}"
}

# merge_ports prints the union of two comma-separated lists, sorted.
merge_ports() {
  printf '%s\n' ${1//,/ } ${2//,/ } | sort -nu | paste -sd, -
}

# check_options rejects unknown options and contradictory combinations.
check_options() {
  local where="$1" opt nports=0; shift
  for opt in "$@"; do
    if [[ "$opt" == port=* ]]; then
      check_ports "$where" "${opt#port=}"
      nports=$((nports + 1))
      continue
    fi
    [[ " $VALID_OPTIONS " == *" $opt "* ]] \
      || die "unknown option '$opt' for $where — valid: ${VALID_OPTIONS// /, }, port=N[,N...]"
  done
  (( nports <= 1 )) || die "$where: port= given more than once"
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
  local nports=0
  for opt in "$@"; do
    if [[ " $VALID_REDIRECT_CODES " == *" $opt "* ]]; then
      [[ -z "$code" ]] || die "$where: more than one status code"
      code="$opt"
    elif [[ "$opt" == port=* ]]; then
      check_ports "$where" "${opt#port=}"
      nports=$((nports + 1))
    elif [[ "$opt" != drop-path ]]; then
      die "$where: unknown redirect option '$opt' — valid: ${VALID_REDIRECT_CODES// /, }, drop-path, port=N[,N...]"
    fi
  done
  (( nports <= 1 )) || die "$where: port= given more than once"

  # A destination under its own source redirects to itself forever.
  local rest="${dest#*://}" dhost dpath=""
  dhost="${rest%%/*}"; dhost="${dhost%%:*}"
  [[ "$rest" == */* ]] && dpath="/${rest#*/}"
  if [[ "${dhost,,}" == "$host" ]] \
     && { [[ -z "$path" ]] || [[ "$dpath" == "$path" || "$dpath" == "$path"/* ]]; }; then
    die "$where: $dest is under $source itself, which would redirect forever"
  fi
}

# read_redirects emits "host|path|dest|code|drop|ports" for each
# active line, longest path first within a host so the most specific prefix
# wins whatever the order of the file.
read_redirects() {
  [[ -f "$REDIRECT_TABLE" ]] || return 0
  local source dest options host path opt code drop ports
  while read -r source dest options; do
    [[ -z "${source:-}" || "${source:0:1}" == "#" ]] && continue
    [[ -n "${dest:-}" ]] || die "line for '$source' in $REDIRECT_TABLE has no destination"
    # shellcheck disable=SC2086
    check_redirect "'$source' in $REDIRECT_TABLE" "$source" "$dest" ${options:-}
    IFS='|' read -r host path < <(split_source "$source")
    code=302 drop=0 ports=443
    for opt in ${options:-}; do
      case "$opt" in
        drop-path) drop=1 ;;
        port=*)    ports="${opt#port=}" ;;
        *)         code="$opt" ;;
      esac
    done
    printf '%s|%s|%s|%s|%s|%s|%s\n' "${#path}" "$host" "$path" "$dest" "$code" "$drop" "$ports"
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

# redirect_rules <scope> emits the http-request rules for the redirects on
# stdin. The scope decides which redirects apply and how the port is checked:
#   tls    decrypted traffic on any port; each rule checks dst_port
#   http80 plain HTTP on 80, i.e. the redirects served on 443; no port check
#   httpx  plain HTTP on the other ports; each rule checks dst_port
redirect_rules() {
  local scope="$1"
  local host path dest code drop ports host_acl location rule_ports p
  while IFS='|' read -r host path dest code drop ports; do
    case "$scope" in
      tls)    rule_ports="${ports//,/ }" ;;
      http80) has_port "$ports" 443 || continue; rule_ports="" ;;
      httpx)
        rule_ports=""
        for p in ${ports//,/ }; do [[ "$p" == 443 ]] || rule_ports+="$p "; done
        [[ -n "$rule_ports" ]] || continue ;;
    esac
    host_acl="{ hdr(host),field(1,:),lower -m str $host }"
    [[ -n "$rule_ports" ]] && host_acl+=" { dst_port ${rule_ports% } }"
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
  # Parse both tables once in this shell first. read_table also feeds the loop
  # below through a process substitution, where its die() would end only that
  # subshell — and an invalid line would then regenerate an empty map, dropping
  # every route instead of refusing to change anything.
  read_table >/dev/null
  read_redirects >/dev/null

  install -d -m 0755 "$CONF_D"

  local tmp_map tmp_cfg tmp_cf tmp_term tmp_rd count=0
  # served: "key|ports|route" for every key with a route on some ports, which
  # drives the per-port listeners and the port checks; route is be_pt_terminate
  # for anything decrypted here. term_rules: "key|ports|backend" for decrypted
  # traffic that goes on to a target. r404: "host|ports" where a host is
  # decrypted only for its redirects, so other paths get 404.
  local terminated=() served=() term_rules=() r404=()
  tmp_map="$(mktemp)"; tmp_cfg="$(mktemp)"; tmp_cf="$(mktemp)"; tmp_term="$(mktemp)"
  tmp_rd="$(mktemp)"
  read_redirects > "$tmp_rd"

  {
    echo "# Generated by passthrough.sh from $TABLE — do not edit."
    echo "# SNI hostname -> backend name, as routed on :443. Every entry is listed,"
    echo "# so a name resolves to its own entry on any port; one not served on 443"
    echo "# maps to be_reject here."
  } > "$tmp_map"
  {
    echo "# Generated by passthrough.sh from $TABLE — do not edit."
    echo "# TLS passthrough backends. Each keeps its own TLS termination,"
    echo "# except the 'terminate' domains further down this file."
    echo
  } > "$tmp_cfg"
  {
    echo "# Generated by passthrough.sh from $TABLE — do not edit."
    echo "# Passthrough SNIs that only Cloudflare's edge may connect to."
  } > "$tmp_cf"

  local domain target options be pp opts ports route
  while IFS=$'\t' read -r domain target options; do
    read -ra opts <<< "$options"
    be="$(backend_name "$domain")"
    ports="$(ports_of "${opts[@]}")"

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
      route=be_pt_terminate
      terminated+=("$domain")
      term_rules+=("$domain|$ports|$be")
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
      route="$be"
      {
        printf 'backend %s\n' "$be"
        printf '    mode tcp\n'
        # These are tunnels, not requests; the default 60s would cut them.
        printf '    timeout server 1h\n'
        printf '    server target %s%s\n\n' "$target" "$pp"
      } >> "$tmp_cfg"
    fi
    if has_port "$ports" 443; then
      printf '%s %s\n' "$domain" "$route" >> "$tmp_map"
    else
      printf '%s be_reject\n' "$domain" >> "$tmp_map"
    fi
    served+=("$domain|$ports|$route")
    count=$((count + 1))
  done < <(read_table)

  # --- HTTP redirects ---
  # A path is only visible once TLS is decrypted. On each of its redirect
  # ports a host is either already decrypted here (its own 'terminate' line,
  # or a 'terminate' wildcard over it, listens there) or is decrypted for its
  # redirects alone, with 404 for other paths. A plain passthrough line on the
  # same port would need the handshake left untouched, so that is refused; on
  # its other ports the line is not affected at all.
  local hubs rhost wild base base_opts base_ports base_route base_be overlap ronly takeover inherit
  local n_redirects
  local -A rports=()
  hubs="$(hub_domains)"
  n_redirects="$(grep -c . "$tmp_rd" || true)"
  while IFS='|' read -r rhost _ _ _ _ ports; do
    rports[$rhost]="$(merge_ports "${rports[$rhost]:-}" "$ports")"
  done < "$tmp_rd"

  while read -r rhost; do
    [[ -n "$rhost" ]] || continue
    ports="${rports[$rhost]}"
    grep -qxF "$rhost" <<< "$hubs" \
      && die "redirect source $rhost is one of the hub's own domains; redirects cannot take those over"

    # The entry the host resolves to without its redirects, if any.
    wild="*.${rhost#*.}"
    base="" base_opts="" base_ports="" base_route="" base_be=""
    for base in "$rhost" "$wild"; do
      base_opts="$(read_table | awk -F'\t' -v d="$base" '$1 == d {print $3 "|"}')"
      [[ -n "$base_opts" ]] && break
    done
    [[ -n "$base_opts" ]] || base=""
    if [[ -n "$base" ]]; then
      base_opts="${base_opts%|}"
      # shellcheck disable=SC2086
      base_ports="$(ports_of $base_opts)"
      base_be="$(backend_name "$base")"
      # shellcheck disable=SC2086
      if has_option terminate $base_opts; then base_route=be_pt_terminate; else base_route="$base_be"; fi
    fi

    overlap="$(ports_and "$ports" "$base_ports")"
    takeover=""
    if [[ -n "$overlap" && "$base_route" != be_pt_terminate ]]; then
      [[ "$base" == "$rhost" ]] \
        && die "redirect source $rhost is a plain passthrough line in $TABLE on port(s) $overlap; its TLS
  is never decrypted there, so no path can be seen. Use another port for the redirect, or add the
  'terminate' option to its line."
      takeover="$overlap"
      log "NOTE: on port(s) $takeover, $rhost now ends here instead of at $wild's target; paths without a redirect get 404"
    fi
    ronly="$(merge_ports "$(ports_minus "$ports" "$base_ports")" "$takeover")"
    [[ -n "$ronly" ]] || continue    # decrypted already wherever it redirects

    if [[ "$base" == "$rhost" ]]; then
      # Its own line keeps its ports; the redirect-only ones are added beside it.
      has_port "$ronly" 443 \
        && awk -v h="$rhost" '$1 == h { $2 = "be_pt_terminate" } { print }' "$tmp_map" > "$tmp_map.new" \
        && mv "$tmp_map.new" "$tmp_map"
    else
      # A name of its own, so it resolves to itself; on the ports it does not
      # redirect on it carries on exactly as the wildcard over it would.
      inherit="$(ports_minus "$base_ports" "$takeover")"
      if has_port "$ronly" 443; then
        printf '%s be_pt_terminate\n' "$rhost" >> "$tmp_map"
      elif [[ -n "$inherit" ]] && has_port "$inherit" 443; then
        printf '%s %s\n' "$rhost" "$base_route" >> "$tmp_map"
      else
        printf '%s be_reject\n' "$rhost" >> "$tmp_map"
      fi
      if [[ -n "$inherit" ]]; then
        served+=("$rhost|$inherit|$base_route")
        [[ "$base_route" == be_pt_terminate ]] && term_rules+=("$rhost|$inherit|$base_be")
      fi
      grep -qxF "$base" "$tmp_cf" && printf '%s\n' "$rhost" >> "$tmp_cf"
    fi
    served+=("$rhost|$ronly|be_pt_terminate")
    r404+=("$rhost|$ronly")
    has_certificate "$rhost" || {
      log "WARNING: no certificate in $CERT_DIR covers $rhost."
      log "  HTTPS redirects are answered here, so HAProxy needs one: add $rhost to"
      log "  /etc/notification-hub/domains.map (format combined, service haproxy),"
      log "  then: sudo /opt/notification-hub/bin/issue-cert.sh $rhost"
    }
  done < <(printf '%s\n' "${!rports[@]}" | sort)

  # Ports other than 443, each with a listener of its own.
  local extra_ports=() item p
  for item in "${served[@]}"; do
    IFS='|' read -r _ ports _ <<< "$item"
    for p in ${ports//,/ }; do [[ "$p" == 443 ]] || extra_ports+=("$p"); done
  done
  mapfile -t extra_ports < <(printf '%s\n' "${extra_ports[@]}" | sed '/^$/d' | sort -nu)
  for p in "${extra_ports[@]}"; do check_listen_port "$p"; done

  if (( ${#term_rules[@]} + ${#r404[@]} )); then
    write_terminate_frontend >> "$tmp_cfg"
    cat "$tmp_term" >> "$tmp_cfg"
  fi
  if (( ${#extra_ports[@]} )); then
    write_port_frontends >> "$tmp_cfg"
  fi

  # Port 80 hands every host with a redirect on 443 to this backend, so a
  # plain-HTTP request goes straight to its destination instead of first being
  # sent to HTTPS on the same host. Paths without a redirect still get that
  # HTTPS upgrade. It is always generated: haproxy.cfg refers to it even when
  # the table is empty.
  {
    echo "#-----------------------------------------------------------------------------"
    echo "# HTTP redirects on port 80, from $REDIRECT_TABLE."
    echo "#-----------------------------------------------------------------------------"
    echo "backend be_http_redirects"
    echo "    mode http"
    redirect_rules http80 < "$tmp_rd"
    echo "    http-request redirect scheme https code 301"
    echo
  } >> "$tmp_cfg"
  {
    echo "# Generated by passthrough.sh from $REDIRECT_TABLE — do not edit."
    echo "# Hosts with HTTP redirects on 443; port 80 sends them to be_http_redirects."
    awk -F'|' '{ if (index("," $6 ",", ",443,")) print $1 }' "$tmp_rd" | sort -u
  } > "$tmp_rd.hosts"

  install -m 0644 "$tmp_map" "$MAP"
  install -m 0644 "$tmp_cfg" "$GENERATED"
  install -m 0644 "$tmp_cf" "$CF_ONLY_LIST"
  install -m 0644 "$tmp_rd.hosts" "$REDIRECT_HOSTS_LIST"
  rm -f "$tmp_map" "$tmp_cfg" "$tmp_cf" "$tmp_term" "$tmp_rd" "$tmp_rd.hosts"
  log "generated $count passthrough backend(s)${terminated[*]:+, ${#terminated[@]} terminated here}, $n_redirects redirect(s)${extra_ports[*]:+, extra port(s) ${extra_ports[*]}}"
}

# check_listen_port refuses a port something other than HAProxy already holds
# (HAProxy would fail to bind it on reload), and says how to open it when ufw
# is active and does not allow it yet. It never changes the firewall itself.
check_listen_port() {
  local port="$1" holder acme
  # certbot binds this only while renewing, so ss would not see the clash.
  # shellcheck disable=SC1090
  acme="$( [[ -r "$HUB_ENV" ]] && (set +u; source "$HUB_ENV" >/dev/null 2>&1; printf '%s' "${ACME_HTTP_PORT:-}") || true)"
  [[ "$port" != "${acme:-8402}" ]] \
    || die "port $port is ACME_HTTP_PORT, where certbot answers challenges; pick another port"
  holder="$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n1 | cut -d'"' -f2 || true)"
  [[ -z "$holder" || "$holder" == haproxy ]] \
    || die "port $port is already used by '$holder'; pick another port"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -q 'active$' \
     && ! ufw status 2>/dev/null | grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW"; then
    log "WARNING: ufw does not allow ${port}/tcp yet, so nothing can reach it. Open it with:"
    log "  sudo ufw allow ${port}/tcp comment 'notification-hub haproxy'"
  fi
}

# port_ok_rules <rule> <route-or-""> <port...> emits, per port, one rule that
# marks the transaction as allowed when its resolved entry is served on the
# port it arrived on, counting only entries with that route when one is given.
# Reads the caller's served array.
port_ok_rules() {
  local rule="$1" only="$2"; shift 2
  local port item key ports route keys
  for port in "$@"; do
    keys=""
    for item in "${served[@]}"; do
      IFS='|' read -r key ports route <<< "$item"
      [[ -z "$only" || "$route" == "$only" ]] || continue
      has_port "$ports" "$port" && [[ " $keys " != *" $key "* ]] && keys+=" $key"
    done
    [[ -n "$keys" ]] && printf '    %s set-var(txn.port_ok) bool(1) if { var(txn.pt_key) -m str%s } { dst_port %s }\n' \
      "$rule" "$keys" "$port"
  done
  return 0
}

# write_terminate_frontend emits the internal frontend that decrypts the
# 'terminate' domains. Passthrough never sees inside the TLS stream, so behind
# Cloudflare it only ever knows the edge's address; decrypting exposes
# CF-Connecting-IP, and after set-src the PROXY header sent to the target
# carries the real client — the same treatment the hub's own domains get.
# Redirects are answered here too, for the same reason: only decrypted traffic
# has a path. dst_port is the port the client connected to, carried in the
# PROXY header from whichever listener accepted it.
#
# Reads the caller's served, term_rules, r404 and tmp_rd.
write_terminate_frontend() {
  local cf_ips="${CLOUDFLARE_IPS_FILE:-/etc/haproxy/cloudflare-ips.lst}"
  local all_ports item ports
  all_ports="$(for item in "${served[@]}"; do IFS='|' read -r _ ports _ <<< "$item"; printf '%s\n' ${ports//,/ }; done | sort -nu | tr '\n' ' ')"
  local key backend
  cat <<EOF
#-----------------------------------------------------------------------------
# 'terminate' domains and redirect hosts: TLS is decrypted here, and for the
# former re-encrypted to the target.
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

    # Likewise a Host that is not served on the port this arrived on.
EOF
  # shellcheck disable=SC2086
  port_ok_rules http-request be_pt_terminate $all_ports
  cat <<EOF
    http-request silent-drop unless { var(txn.port_ok) -m found }

    # CF-Connecting-IP is trusted only from Cloudflare's ranges, exactly as on
    # the hub's frontend; from anyone else it is deleted, so it cannot be forged.
    acl has_cf_ip req.hdr(CF-Connecting-IP) -m found
    http-request set-src req.hdr(CF-Connecting-IP) if from_cloudflare has_cf_ip
    http-request del-header CF-Connecting-IP unless from_cloudflare
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-For %[src]

    acl acme_challenge path_beg /.well-known/acme-challenge/
    use_backend be_acme if acme_challenge
EOF
  if [[ -s "$tmp_rd" ]]; then
    echo
    echo "    # HTTP redirects, from $REDIRECT_TABLE. Longest prefix first per host."
    redirect_rules tls < "$tmp_rd"
  fi
  if (( ${#r404[@]} )); then
    echo "    # Decrypted only for their redirects on these ports."
    for item in "${r404[@]}"; do
      IFS='|' read -r key ports <<< "$item"
      printf '    http-request return status 404 content-type text/plain string "Not found" if { var(txn.pt_key) -m str %s } { dst_port %s }\n' \
        "$key" "${ports//,/ }"
    done
  fi
  for item in "${term_rules[@]}"; do
    IFS='|' read -r key ports backend <<< "$item"
    printf '    use_backend %s if { var(txn.pt_key) -m str %s } { dst_port %s }\n' \
      "$backend" "$key" "${ports//,/ }"
  done
  echo
}

# write_port_frontends emits a listener for every port other than 443. Each
# accepts TLS for the entries naming that port, routed exactly as on 443, and
# plain HTTP for them, which pt_http_in redirects to https on the same port.
# Anything else — another SNI, another Host, neither TLS nor HTTP — is silently
# dropped, so the client is left to time out.
#
# Reads the caller's served and extra_ports.
write_port_frontends() {
  local cf_ips="${CLOUDFLARE_IPS_FILE:-/etc/haproxy/cloudflare-ips.lst}"
  local port item key ports route
  for port in "${extra_ports[@]}"; do
    cat <<EOF
#-----------------------------------------------------------------------------
# Port $port: only the entries that name it.
#-----------------------------------------------------------------------------
frontend pt_port_$port
    bind *:$port
    mode tcp
    option tcplog
    timeout client 1h
    tcp-request inspect-delay 5s

    acl tls_hello       req.ssl_hello_type 1
    acl is_http         req.proto_http
    acl from_cloudflare src -f $cf_ips
    acl pt_found        var(txn.pt_key) -m found
    tcp-request content set-var(txn.pt_key) req.ssl_sni,lower if tls_hello { req.ssl_sni,lower,map($MAP) -m found }
    tcp-request content set-var(txn.pt_key) req.ssl_sni,lower,regsub(^[^.]+[.],*.) if tls_hello !pt_found { req.ssl_sni,lower,regsub(^[^.]+[.],*.),map($MAP) -m found }
    tcp-request content silent-drop if !from_cloudflare { var(txn.pt_key) -m str -f $CF_ONLY_LIST }
    tcp-request content accept if tls_hello
    tcp-request content accept if is_http

EOF
    for item in "${served[@]}"; do
      IFS='|' read -r key ports route <<< "$item"
      has_port "$ports" "$port" || continue
      printf '    use_backend %s if tls_hello { var(txn.pt_key) -m str %s }\n' "$route" "$key"
    done
    printf '    use_backend be_pt_http if is_http\n'
    printf '    default_backend be_reject\n\n'
  done

  cat <<EOF
#-----------------------------------------------------------------------------
# Plain HTTP on the ports above: redirects, then https on the same port.
#-----------------------------------------------------------------------------
backend be_pt_http
    mode tcp
    server local_pt_http abns@pt-http send-proxy-v2

frontend pt_http_in
    mode http
    bind abns@pt-http accept-proxy

    acl pt_found var(txn.pt_key) -m found
    http-request set-var(txn.pt_key) hdr(host),field(1,:),lower if { hdr(host),field(1,:),lower,map($MAP) -m found }
    http-request set-var(txn.pt_key) hdr(host),field(1,:),lower,regsub(^[^.]+[.],*.) if !pt_found { hdr(host),field(1,:),lower,regsub(^[^.]+[.],*.),map($MAP) -m found }

    acl from_cloudflare src -f $cf_ips
    acl cf_only_host    var(txn.pt_key) -m str -f $CF_ONLY_LIST
    http-request silent-drop if cf_only_host !from_cloudflare
EOF
  port_ok_rules http-request "" "${extra_ports[@]}"
  echo "    http-request silent-drop unless { var(txn.port_ok) -m found }"
  echo
  redirect_rules httpx < "$tmp_rd"
  echo '    http-request redirect location https://%[hdr(host),field(1,:),lower]:%[dst_port]%[pathq] code 301'
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
      local host path dest code drop ports
      while IFS='|' read -r host path dest code drop ports; do
        (( drop )) && code+=" drop-path"
        [[ "$ports" == 443 ]] || code+=" port=$ports"
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
