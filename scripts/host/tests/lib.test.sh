#!/usr/bin/env bash
# Tests for the lib.sh helpers that let a Piri join a running node without a
# platform restart, run from any machine:
#
#   scripts/host/tests/lib.test.sh
#
# Each case sources lib.sh in a subshell with a stub docker first on PATH and
# compose_platform replaced by a function that answers from files. The docker
# stub appends every call to a log and keeps what `docker exec` read on stdin.
# Nothing outside the temporary directory changes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)/lib.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lib-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
current=""

pass() { printf '  ok   %s\n' "$current: $1"; }
flunk() {
  printf '  FAIL %s\n' "$current: $1"
  failures=$((failures + 1))
}
lacks() { ! grep -qF -- "$1" "$2"; } # lacks <text> <file>
check() { # check <description> <command...>
  local description="$1"
  shift
  if "$@"; then pass "$description"; else flunk "$description"; fi
}

# shellcheck source=../lib.sh
. "$LIB"

# --- Fixture ---------------------------------------------------------------

# The stubs below replace lib.sh's own definitions, so they come after it.

# A fresh node directory, state directory and stub docker for one case.
# Sets STUB_STATE, FILONE_NODE_DIR and FILONE_STATE_DIR.
new_case() {
  current="$1"
  failures=0
  local root="$WORK/$1"
  mkdir -p "$root/bin" "$root/stub" "$root/node/platform/config/caddy" "$root/state"
  STUB_STATE="$root/stub"
  FILONE_NODE_DIR="$root/node"
  FILONE_STATE_DIR="$root/state"
  export STUB_STATE

  cat >"$root/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_STATE/calls"
case "$1" in
  # Like Compose, refuse an --env-file that does not exist. The platform's live
  # on a tmpfs, so they are gone after a reboot until a platform deploy.
  compose)
    previous=""
    for arg in "$@"; do
      if [ "$previous" = --env-file ] && [ ! -e "$arg" ]; then exit 1; fi
      previous="$arg"
    done
    ;;
  ps) cat "$STUB_STATE/container" ;;
  inspect) cat "$STUB_STATE/running-image" ;;
  image) cat "$STUB_STATE/desired-image" ;;
  exec)
    printf '%s' "${PGPASSWORD:-}" >"$STUB_STATE/exec-pgpassword"
    cat >"$STUB_STATE/exec-stdin"
    ;;
esac
STUB
  chmod +x "$root/bin/docker"
  PATH="$root/bin:$PATH"

  printf 'any-image-id\n' >"$STUB_STATE/running-image"
  printf 'any-image-id\n' >"$STUB_STATE/desired-image"
  printf 'any-container\n' >"$STUB_STATE/container"
  printf 'https://piri-0.any-suffix {\n}\n' >"$FILONE_NODE_DIR/platform/config/caddy/Caddyfile"
  write_caddy_definition 'PIRI_HOSTNAME_SUFFIX=any-suffix'
}

# The platform project's resolved definition: one caddy service with the given
# environment entry and the Caddyfile bind-mounted from the node directory.
write_caddy_definition() {
  cat >"$STUB_STATE/config.json" <<JSON
{"services": {"caddy": {
  "image": "caddy@sha256:any",
  "environment": ["$1"],
  "volumes": [{"type": "bind",
               "source": "$FILONE_NODE_DIR/platform/config/caddy/Caddyfile",
               "target": "/etc/caddy/Caddyfile"}]
}}}
JSON
}

# Replaces lib.sh's compose_platform, which needs a node's env files.
compose_platform() {
  echo "compose $*" >>"$STUB_STATE/calls"
  case "$1" in
    config) cat "$STUB_STATE/config.json" ;;
    ps) cat "$STUB_STATE/container" ;;
  esac
}

# Record the Caddy definition as the last deploy would have.
record_caddy_definition() {
  config_hash_record platform-caddy-definition \
    "$(compose_config_hash compose_platform caddy definition)"
}

# --- ensure_piri_database ----------------------------------------------------

(
  new_case "creates a missing Piri database named after its service"
  POSTGRES_ADMIN_PASSWORD=any-password
  ensure_piri_database piri-3
  check "sends a guarded CREATE for piri_3 owned by piri" \
    grep -qF "SELECT 'CREATE DATABASE \"piri_3\" OWNER \"piri\"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'piri_3')" \
    "$STUB_STATE/exec-stdin"
  check "passes the admin password through the environment" \
    [ "$(cat "$STUB_STATE/exec-pgpassword")" = any-password ]
  check "never puts the admin password on the command line" \
    lacks any-password "$STUB_STATE/calls"
  [ "$failures" -eq 0 ]
) || {
  failures=$((failures + 1))
  echo "  FAIL the case above stopped early; the ERROR line before it says why"
}

(
  # No platform.env or openbao.env exist here, as on a node after a reboot,
  # where reconcile runs the apps deploy without a platform deploy first.
  new_case "creates the database when the platform's env files are gone"
  POSTGRES_ADMIN_PASSWORD=any-password
  ensure_piri_database piri-0
  check "finds Postgres by its compose labels" \
    grep -qF "docker ps -q --filter label=com.docker.compose.project=filone-platform --filter label=com.docker.compose.service=postgres" \
    "$STUB_STATE/calls"
  check "sends the CREATE to that container" \
    grep -qF "docker exec -i -e PGPASSWORD any-container psql" "$STUB_STATE/calls"
  [ "$failures" -eq 0 ]
) || {
  failures=$((failures + 1))
  echo "  FAIL the case above stopped early; the ERROR line before it says why"
}

(
  new_case "refuses a service name that is not a Piri"
  POSTGRES_ADMIN_PASSWORD=any-password
  # A quote and a semicolon would reach the SQL unescaped.
  if (ensure_piri_database "piri-3'; DROP DATABASE ingot; --") 2>/dev/null; then
    flunk "returned success"
  else
    pass "fails"
  fi
  check "runs nothing in Postgres" [ ! -e "$STUB_STATE/exec-stdin" ]
  [ "$failures" -eq 0 ]
) || {
  failures=$((failures + 1))
  echo "  FAIL the case above stopped early; the ERROR line before it says why"
}

# --- caddy_only_caddyfile_changed ------------------------------------------

(
  new_case "reloads when only the Caddyfile changed"
  record_caddy_definition
  printf 'https://piri-3.any-suffix {\n}\n' >>"$FILONE_NODE_DIR/platform/config/caddy/Caddyfile"
  check "reports a Caddyfile-only change" caddy_only_caddyfile_changed
  [ "$failures" -eq 0 ]
) || {
  failures=$((failures + 1))
  echo "  FAIL the case above stopped early; the ERROR line before it says why"
}

(
  new_case "recreates when Caddy's environment changed"
  record_caddy_definition
  write_caddy_definition 'PIRI_HOSTNAME_SUFFIX=other-suffix'
  if caddy_only_caddyfile_changed; then flunk "reported a Caddyfile-only change"; else pass "does not report a Caddyfile-only change"; fi
  [ "$failures" -eq 0 ]
) || {
  failures=$((failures + 1))
  echo "  FAIL the case above stopped early; the ERROR line before it says why"
}

(
  new_case "recreates when Caddy's image changed"
  record_caddy_definition
  printf 'other-image-id\n' >"$STUB_STATE/desired-image"
  if caddy_only_caddyfile_changed; then flunk "reported a Caddyfile-only change"; else pass "does not report a Caddyfile-only change"; fi
  [ "$failures" -eq 0 ]
) || {
  failures=$((failures + 1))
  echo "  FAIL the case above stopped early; the ERROR line before it says why"
}

(
  new_case "recreates when no Caddy definition was recorded"
  if caddy_only_caddyfile_changed; then flunk "reported a Caddyfile-only change"; else pass "does not report a Caddyfile-only change"; fi
  [ "$failures" -eq 0 ]
) || {
  failures=$((failures + 1))
  echo "  FAIL the case above stopped early; the ERROR line before it says why"
}

# --- reload_caddy ------------------------------------------------------------

(
  new_case "reloads the checkout's Caddyfile into the running Caddy"
  printf 'https://piri-3.any-suffix {\n}\n' >"$FILONE_NODE_DIR/platform/config/caddy/Caddyfile"
  reload_caddy
  check "sends the checkout's Caddyfile on stdin" \
    cmp -s "$STUB_STATE/exec-stdin" "$FILONE_NODE_DIR/platform/config/caddy/Caddyfile"
  check "runs caddy reload in the Caddy container" \
    grep -qF "docker exec -i any-container sh -c cat >/tmp/Caddyfile && caddy reload --config /tmp/Caddyfile --adapter caddyfile" \
    "$STUB_STATE/calls"
  [ "$failures" -eq 0 ]
) || {
  failures=$((failures + 1))
  echo "  FAIL the case above stopped early; the ERROR line before it says why"
}

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
