#!/usr/bin/env bash
# One shared PostgreSQL instance, one database + owning role per service.
#
# Nothing listens on TCP: native services (ntfy, Miniflux) connect over the unix
# socket, and the healthchecks container gets that socket directory bind-mounted
# in. Each role can only connect to its own database, so one leaked service
# credential does not expose the others.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

apt_ensure postgresql postgresql-client
systemctl enable --now postgresql >/dev/null

PG_SOCKET_DIR="${PG_SOCKET_DIR:-/var/run/postgresql}"

psql_super() { su - postgres -c "psql -v ON_ERROR_STOP=1 -qtAX -c \"$1\""; }

role_exists() {
  [[ "$(su - postgres -c "psql -tAX -c \"SELECT 1 FROM pg_roles WHERE rolname='$1'\"")" == "1" ]]
}
db_exists() {
  [[ "$(su - postgres -c "psql -tAX -c \"SELECT 1 FROM pg_database WHERE datname='$1'\"")" == "1" ]]
}

# provision <db> <role> <env-var-holding-password>
provision() {
  local db="$1" role="$2" var="$3" password

  password="$(set_env_var "$var" "$(gen_secret 32)")"

  if role_exists "$role"; then
    psql_super "ALTER ROLE \\\"$role\\\" WITH LOGIN PASSWORD '$password'"
  else
    log "creating role $role"
    psql_super "CREATE ROLE \\\"$role\\\" WITH LOGIN PASSWORD '$password'"
  fi

  if ! db_exists "$db"; then
    log "creating database $db owned by $role"
    su - postgres -c "createdb -O '$role' '$db'"
  fi

  # Only the owner may connect. Without this, every role on the instance can open
  # every database by default.
  psql_super "REVOKE CONNECT ON DATABASE \\\"$db\\\" FROM PUBLIC"
  psql_super "GRANT ALL PRIVILEGES ON DATABASE \\\"$db\\\" TO \\\"$role\\\""

  # Django (healthchecks) creates its own tables, so it needs the public schema.
  su - postgres -c "psql -v ON_ERROR_STOP=1 -qtAX -d '$db' -c 'GRANT ALL ON SCHEMA public TO \"$role\"'"
}

provision ntfy         ntfy         PG_NTFY_PASSWORD
provision miniflux     miniflux     PG_MINIFLUX_PASSWORD
provision healthchecks healthchecks PG_HEALTHCHECKS_PASSWORD

# Socket connections authenticate with a password rather than peer, because the
# healthchecks container's UID does not match any host user.
PG_HBA="$(su - postgres -c 'psql -tAX -c "SHOW hba_file"')"
MARKER="# notification-hub"
if ! grep -q "$MARKER" "$PG_HBA"; then
  log "adding pg_hba rules to $PG_HBA"
  cp "$PG_HBA" "$PG_HBA.nh-backup.$(date +%s)"
  # Prepended, because pg_hba is first-match-wins and the distro's generic
  # "local all all peer" line would otherwise shadow these.
  tmp="$(mktemp)"
  {
    echo "$MARKER — service accounts authenticate by password over the unix socket"
    echo "local   ntfy            ntfy            scram-sha-256"
    echo "local   miniflux        miniflux        scram-sha-256"
    echo "local   healthchecks    healthchecks    scram-sha-256"
    echo "$MARKER end"
    echo
    cat "$PG_HBA"
  } > "$tmp"
  install -o postgres -g postgres -m 0640 "$tmp" "$PG_HBA"
  rm -f "$tmp"
  systemctl reload postgresql
fi

# Confirm we did not accidentally expose a TCP listener.
if ss -ltn 2>/dev/null | grep -qE ':5432\b'; then
  warn "PostgreSQL is listening on TCP:5432 — the design expects unix-socket-only access"
fi

log "postgres ready (socket: $PG_SOCKET_DIR)"
