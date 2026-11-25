#!/usr/bin/env bash
# Tests for the Piri rollout in scripts/host/deploy-apps.sh, run from any
# machine with bash 4 or later:
#
#   scripts/host/tests/deploy-apps.test.sh
#
# Covers a Piri that never comes up healthy: the other Piris and Ingot are
# still started, the deploy fails naming it, and nothing records it as
# deployed. Also a Piri whose proving gate never opens, and a rollout halted by
# a Piri recreated for a change.
#
# deploy-apps.sh runs from a copy in a temporary directory, next to a stub
# lib.sh that answers for OpenBao, compose and Docker, and stub pdp-gate.sh and
# deploy-rag.sh. Each case sets which Piris are running, which changed, which
# never turn healthy and whose gate never opens. Every compose up, gate, hash
# record and stamp is appended to $STUB_STATE/calls.
set -euo pipefail

# deploy-apps.sh uses associative arrays, which the bash 3.2 macOS ships lacks.
# CI runs this on Linux.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "SKIPPED: deploy-apps.sh needs bash 4 or later; this is bash $BASH_VERSION"
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-apps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
current=""

pass() { printf '  ok   %s\n' "$current: $1"; }
flunk() {
  printf '  FAIL %s\n' "$current: $1"
  failures=$((failures + 1))
}
check() { # check <description> <command...>
  local description="$1"
  shift
  if "$@"; then pass "$description"; else flunk "$description"; fi
}

# --- Stubs -------------------------------------------------------------------

HOST="$WORK/host"
mkdir -p "$HOST"
cp "$SCRIPTS/deploy-apps.sh" "$HOST/"

# STUB_RUNNING, STUB_CHANGED, STUB_BROKEN and STUB_GATE_FAILS each list Piri
# service names, or ingot for STUB_BROKEN.
cat >"$HOST/lib.sh" <<'STUB'
die() { echo "DIE: $*" >&2; exit 1; }
listed() { [[ " $1 " == *" $2 "* ]]; }
filone_init() {
  PAYER_ADDRESS=0x1 FILONE_NODE=test FILONE_NODE_DIR="$STUB_STATE" FILONE_SECRETS_DIR="$STUB_STATE"
  FILONE_APPS_DEPLOYED_MARKER="$STUB_STATE/apps-deployed"
}
take_deploy_lock() { :; }
bao_is_unsealed() { :; }
require_apps_inputs() { :; }
require_configured() { :; }
require_apps_secrets() { :; }
piri_services() { printf '%s\n' piri-0 piri-1 piri-2; }
apps_core_services() { printf '%s\n' ingot piri-0 piri-1 piri-2; }
piri_containers() { printf '%s\n' filone-piri-0 filone-piri-1 filone-piri-2; }
is_mounted() { :; }
piri_data_dir() { echo /data; }
create_volume_dirs() { :; }
bao_get() { echo value; }
bao_has() { :; }
ensure_app_database() { :; }
piri_wallet_hex() { echo hex; }
piri_uses_s3() { return 1; }
mark() {
  local -n flag="$1"
  shift
  if "$@"; then flag=1; fi
}
write_secret_file() { return 1; }
render_template() { return 1; }
compose_apps() {
  case "$1" in
    config) echo '{"services": {"ingot": {"image": "i@sha256:1"}, "piri-0": {"image": "p@sha256:1"},
      "piri-1": {"image": "p@sha256:1"}, "piri-2": {"image": "p@sha256:1"}}}' ;;
    up) echo "$*" >>"$STUB_STATE/calls" ;;
  esac
}
image_differs() { listed "$STUB_CHANGED" "$2"; }
compose_config_hash() { echo hash; }
config_changed() { return 1; }
container_running() { listed "$STUB_RUNNING" "${1#filone-}"; }
wait_healthy() {
  local service
  shift 2
  for service in "$@"; do
    ! listed "$STUB_BROKEN" "$service" || die "$service is unhealthy"
  done
}
config_hash_record() { echo "record $1" >>"$STUB_STATE/calls"; }
stamp_deploy_success() { echo "stamp $1" >>"$STUB_STATE/calls"; }
request_openbao_snapshot() { :; }
STUB

cat >"$HOST/pdp-gate.sh" <<'STUB'
#!/usr/bin/env bash
echo "gate $*" >>"$STUB_STATE/calls"
[[ " $STUB_GATE_FAILS " != *" $1 "* ]]
STUB
printf '#!/usr/bin/env bash\n' >"$HOST/deploy-rag.sh"
chmod +x "$HOST"/*.sh

# --- Cases -------------------------------------------------------------------

case_count=0
# deploy <running> <changed> <broken> <gate fails>, each a space-separated list
deploy() {
  current="$1"
  case_count=$((case_count + 1))
  STUB_STATE="$WORK/case$case_count"
  mkdir -p "$STUB_STATE"
  : >"$STUB_STATE/calls"
  export STUB_STATE STUB_RUNNING="$2" STUB_CHANGED="$3" STUB_BROKEN="$4" STUB_GATE_FAILS="$5"
  status=0
  bash "$HOST/deploy-apps.sh" >"$STUB_STATE/output" 2>&1 || status=$?
}
called() { grep -qxE "$1" "$STUB_STATE/calls"; }
not_called() { ! called "$1"; }
said() { grep -qF -- "$1" "$STUB_STATE/output"; }

echo "==> a Piri that never comes up healthy"

deploy "nothing changed, everything stopped, piri-0 broken" "" "" piri-0 ""
check "tries piri-0" called "up -d --no-recreate --no-deps piri-0"
check "starts piri-1" called "up -d --no-recreate --no-deps piri-1"
check "starts piri-2" called "up -d --no-recreate --no-deps piri-2"
check "starts Ingot" called "up -d --no-recreate ingot"
check "fails" test "$status" -ne 0
check "names piri-0 in the failure" said "deployed every app but piri-0, which did not come up healthy"
check "records the Piris that came up" eval 'called "record apps-piri-1" && called "record apps-piri-2"'
check "does not record piri-0" not_called "record apps-piri-0"
check "does not stamp a success" not_called "stamp apps"

deploy "nothing changed, everything stopped, Ingot broken" "" "" ingot ""
check "starts every Piri" eval 'called "up .* piri-0" && called "up .* piri-1" && called "up .* piri-2"'
check "fails" test "$status" -ne 0
check "does not stamp a success" not_called "stamp apps"

echo "==> a rollout"

deploy "every Piri changed, piri-0 broken, piri-1 running, piri-2 stopped" \
  piri-1 "piri-0 piri-1 piri-2" piri-0 ""
check "recreates piri-0" called "up -d --force-recreate --no-deps piri-0"
check "leaves the running piri-1 alone" not_called "up .*piri-1"
check "says why piri-1 was left" said "piri-1: something changed; left running as it is because the rollout halted at piri-0"
check "recreates the stopped piri-2" called "up -d --force-recreate --no-deps piri-2"
check "starts Ingot" called "up -d --no-recreate ingot"
check "fails naming piri-0 and piri-1" said "deployed every app but piri-0 piri-1,"
check "records only piri-2" eval 'called "record apps-piri-2" && not_called "record apps-piri-[01]"'

deploy "piri-0 changed, its gate never opens" "piri-0 piri-1 piri-2" piri-0 "" piri-0
check "does not recreate piri-0" not_called "up .*piri-0"
check "starts piri-1" called "up -d --no-recreate --no-deps piri-1"
check "starts Ingot" called "up -d --no-recreate ingot"
check "fails naming piri-0" said "deployed every app but piri-0,"

deploy "every Piri changed, piri-0's gate never opens, piri-1 running, piri-2 stopped" \
  "piri-0 piri-1" "piri-0 piri-1 piri-2" "" piri-0
check "does not wait on piri-1's gate" not_called "gate piri-1"
check "leaves the running piri-1 alone" not_called "up .*piri-1"
check "recreates the stopped piri-2" called "up -d --force-recreate --no-deps piri-2"
check "starts Ingot" called "up -d --no-recreate ingot"

deploy "every Piri changed, all healthy" "piri-0 piri-1 piri-2" "piri-0 piri-1 piri-2" "" ""
for service in piri-0 piri-1 piri-2; do
  check "gates and recreates $service" \
    eval "called 'gate $service' && called 'up -d --force-recreate --no-deps $service'"
done
check "succeeds" test "$status" -eq 0
check "stamps a success" called "stamp apps"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
