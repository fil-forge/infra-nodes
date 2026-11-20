#!/usr/bin/env bash
# Tests for scripts/host/reconcile.sh, run from any machine:
#
#   scripts/host/tests/reconcile.test.sh
#
# Covers what a pass deploys: the platform and the apps, the Bucket
# Intelligence and import service retries, and the import service's firewall,
# and that a failed apps deploy or an unreachable OpenBao fails the pass.
#
# reconcile.sh and lib.sh run as root against /etc/fil-one, /run/fil-one and
# /mnt/fil-one. Each case copies them into a temporary directory with those
# paths, and /etc/systemd, moved under the case's own root, and runs the copy.
# Stub docker, id, stat, install, flock and systemctl commands come first on
# PATH; the docker stub answers `bao` calls from files and appends every call to
# a log. The checkout is a real git clone of a local origin, and its deploy
# scripts are stubs that record that they ran. Nothing outside the temporary
# directory changes, even on a host with FilOne installed.
#
# Plain bash plus git and jq, which reconcile.sh needs itself, and written for
# the bash 3.2 macOS ships as well as for a current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
REAL_INSTALL="$(command -v install)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

NODE=testnode

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

write_stubs() {
  local bin="$1"

  # OpenBao's KV store is a directory per path under $STUB_STATE/bao, with a
  # file per field. A file bao-down makes every bao call fail, the way a sealed
  # or unreachable OpenBao does.
  cat >"$bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_STATE/calls"
[ "$1" != stop ] || [ ! -e "$STUB_STATE/docker-stop-fails" ] || exit 1
[ "$1" = exec ] || exit 0
while [ "$#" -gt 0 ] && [ "$1" != bao ]; do shift; done
shift
[ -e "$STUB_STATE/bao-down" ] && exit 2
case "$1 $2" in
  "token renew") exit 0 ;;
  "kv get")
    field="" path=""
    for arg in "${@:3}"; do
      case "$arg" in
        -field=*) field="${arg#-field=}" ;;
        -*) ;;
        *) path="$arg" ;;
      esac
    done
    [ -d "$STUB_STATE/bao/$path" ] || exit 2
    [ -n "$field" ] || exit 0
    [ -f "$STUB_STATE/bao/$path/$field" ] || exit 1
    cat "$STUB_STATE/bao/$path/$field" ;;
  *) exit 0 ;;
esac
STUB

  printf '#!/usr/bin/env bash\necho 0\n' >"$bin/id"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/flock"

  # is_mounted compares a directory's device with the root's.
  cat >"$bin/stat" <<'STUB'
#!/usr/bin/env bash
[ "${*: -1}" = / ] && echo 1 || echo 2
STUB

  # Nothing is enabled, so no snapshot is ever requested.
  cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_STATE/calls"
exit 1
STUB

  # The real install, without the root ownership a test run cannot set.
  cat >"$bin/install" <<STUB
#!/usr/bin/env bash
args=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o | -g) shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
exec "$REAL_INSTALL" "\${args[@]}"
STUB

  chmod +x "$bin"/*
}

# A deploy script in the checkout that records it ran and succeeds, unless a
# file fail-<name> is in the stub state. The apps deploy fails, as the real
# one does, when OpenBao holds no hilt proof.
write_deploy_stub() {
  local name="$1"
  {
    echo '#!/usr/bin/env bash'
    if [ "$name" = import-firewall.sh ]; then
      # `loaded` answers whether the table is in force, from a file.
      # shellcheck disable=SC2016 # expanded by the stub, not here
      echo 'if [ "${1:-}" = loaded ]; then echo "import-firewall.sh loaded" >>"$STUB_STATE/deploys"; [ -e "$STUB_STATE/firewall-loaded" ]; exit; fi'
    fi
    # shellcheck disable=SC2016 # expanded by the stub, not here
    printf 'echo %s >>"$STUB_STATE/deploys"\n' "$name"
    # shellcheck disable=SC2016 # expanded by the stub, not here
    printf '[ ! -e "$STUB_STATE/fail-%s" ] || exit 1\n' "$name"
    if [ "$name" = deploy-apps.sh ]; then
      # shellcheck disable=SC2016 # expanded by the stub, not here
      echo '[ -f "$STUB_STATE/bao/ingot/hilt_proof" ] ||
  { echo "ERROR: OpenBao has no hilt-to-ingot delegation" >&2; exit 1; }'
    fi
  } >"$ORIGIN_WORK/scripts/host/$name"
  chmod +x "$ORIGIN_WORK/scripts/host/$name"
}

# --- Cases -------------------------------------------------------------------

new_case() {
  current="$1"
  CASE="$WORK/case-$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' -)"
  ROOT="$CASE/root"
  STUB_STATE="$CASE/state"
  BIN="$CASE/bin"
  SRC="$CASE/src"
  COPY="$CASE/copy"
  ORIGIN="$CASE/origin.git"
  ORIGIN_WORK="$CASE/origin-work"
  CHECKOUT="$ROOT/opt/fil-one"
  mkdir -p "$ROOT/etc/fil-one" "$ROOT/etc/systemd/system" "$ROOT/run/fil-one" \
    "$ROOT/mnt/fil-one/control" "$ROOT/mnt/fil-one/data" "$STUB_STATE" "$BIN" "$SRC"
  : >"$STUB_STATE/calls"
  : >"$STUB_STATE/deploys"
  write_stubs "$BIN"

  # The node's repository: the node's configuration, both projects and stub
  # deploy scripts, committed to an origin the checkout tracks.
  mkdir -p "$ORIGIN_WORK/nodes/$NODE/apps" "$ORIGIN_WORK/nodes/$NODE/platform" \
    "$ORIGIN_WORK/scripts/host" "$ORIGIN_WORK/systemd"
  cat >"$ORIGIN_WORK/nodes/$NODE/node.env" <<ENV
FILONE_NODE=$NODE
STAGE=test
REGION_LABEL=test-1
FILONE_TAKES_BACKUPS=false
ENV
  echo "services: {}" >"$ORIGIN_WORK/nodes/$NODE/apps/compose.yml"
  echo "services: {}" >"$ORIGIN_WORK/nodes/$NODE/platform/compose.yml"
  write_deploy_stub deploy-platform.sh
  write_deploy_stub deploy-apps.sh
  write_deploy_stub deploy-rag.sh
  write_deploy_stub deploy-import.sh
  write_deploy_stub import-firewall.sh
  touch "$ORIGIN_WORK/systemd/.keep"
  git -C "$ORIGIN_WORK" init --quiet -b main
  git -C "$ORIGIN_WORK" add -A
  # No signing: a developer whose git signs every commit has no key for this
  # identity.
  git -C "$ORIGIN_WORK" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
    commit --quiet -m "node"
  git clone --quiet --bare "$ORIGIN_WORK" "$ORIGIN"
  git clone --quiet "$ORIGIN" "$CHECKOUT"

  cat >"$ROOT/etc/fil-one/node.conf" <<CONF
FILONE_NODE=$NODE
FILONE_CHECKOUT=$CHECKOUT
FILONE_GIT_REF=main
CONF
  echo host-token >"$ROOT/etc/fil-one/bao-token"

  # A provisioned node: Ingot has its identity and its region-key token.
  bao_put ingot identity_pem pem
  bao_put ingot regionkey_token token

  # The code under test, with its absolute paths moved under the case root.
  cp -R "$SCRIPTS/reconcile.sh" "$SCRIPTS/lib.sh" "$SCRIPTS/lib" "$SRC/"
  local file
  for file in "$SRC/reconcile.sh" "$SRC/lib.sh" "$SRC"/lib/*.sh; do
    sed -e "s#/etc/fil-one#$ROOT/etc/fil-one#g" \
      -e "s#/etc/systemd#$ROOT/etc/systemd#g" \
      -e "s#/run/fil-one#$ROOT/run/fil-one#g" \
      -e "s#/mnt/fil-one#$ROOT/mnt/fil-one#g" "$file" >"$file.new"
    mv "$file.new" "$file"
  done
}

bao_put() { # bao_put <path> <field> <value>
  mkdir -p "$STUB_STATE/bao/$1"
  printf '%s' "$3" >"$STUB_STATE/bao/$1/$2"
}

run_reconcile() {
  status=0
  # A fresh copy each pass: reconcile.sh removes the one it ran from on exit.
  rm -rf "$COPY"
  cp -R "$SRC" "$COPY"
  : >"$STUB_STATE/deploys"
  PATH="$BIN:$PATH" STUB_STATE="$STUB_STATE" FILONE_RECONCILE_COPY="$COPY" \
    bash "$COPY/reconcile.sh" >"$CASE/output" 2>&1 || status=$?
}

succeeded() { [ "$status" -eq 0 ]; }
failed() { [ "$status" -ne 0 ]; }
said() { grep -qF -- "$1" "$CASE/output"; }
not_said() { ! said "$1"; }
deployed() { grep -qx "$1" "$STUB_STATE/deploys"; }
not_deployed() { ! deployed "$1"; }
no_deploys() { [ ! -s "$STUB_STATE/deploys" ]; }
only_deployed() { [ "$(cat "$STUB_STATE/deploys")" = "$1" ]; }
stamped() { [ -f "$ROOT/mnt/fil-one/control/state/deploys/$1" ]; }
stopped() { grep -qx "docker stop $1" "$STUB_STATE/calls"; }
not_stopped() { ! grep -q '^docker stop' "$STUB_STATE/calls"; }

show_output_on_failure() {
  local before="$1"
  [ "$failures" -eq "$before" ] && return 0
  sed 's/^/       | /' "$CASE/output"
}

new_case "onboarded"
bao_put ingot hilt_proof proof
before=$failures
run_reconcile
check "exits zero" succeeded
check "deploys the platform" deployed deploy-platform.sh
check "deploys the apps" deployed deploy-apps.sh
show_output_on_failure "$before"

new_case "not onboarded"
# No hilt proof, so the apps deploy refuses. The pass has to fail rather than
# go green with the apps down.
before=$failures
run_reconcile
check "exits non-zero" failed
check "attempts the apps deploy" deployed deploy-apps.sh
show_output_on_failure "$before"

new_case "OpenBao sealed or unreachable"
touch "$STUB_STATE/bao-down"
before=$failures
run_reconcile
check "exits non-zero" failed
check "deploys nothing" not_deployed deploy-platform.sh
check "does not stamp the reconcile pass" eval '! stamped reconcile'
show_output_on_failure "$before"

# A node whose platform and apps are deployed at HEAD since boot, so a pass has
# nothing to deploy unless a retry marker asks for one.
deployed_at_head() {
  local state="$ROOT/mnt/fil-one/control/state"
  bao_put ingot hilt_proof proof
  mkdir -p "$state/revisions"
  git -C "$CHECKOUT" rev-parse HEAD >"$state/revisions/platform"
  git -C "$CHECKOUT" rev-parse HEAD >"$state/revisions/apps"
  touch "$ROOT/run/fil-one/apps-deployed"
}

new_case "deployed, nothing to retry"
deployed_at_head
before=$failures
run_reconcile
check "exits zero" succeeded
check "deploys nothing" no_deploys
show_output_on_failure "$before"

new_case "deployed, an import service deploy to retry"
deployed_at_head
touch "$ROOT/mnt/fil-one/control/state/import-retry"
before=$failures
run_reconcile
check "exits zero" succeeded
check "retries the import service" deployed deploy-import.sh
check "and nothing else" only_deployed deploy-import.sh
check "says so" said "the import service has a deploy to retry"
show_output_on_failure "$before"

current="deployed, the import service retry fails"
touch "$STUB_STATE/fail-deploy-import.sh"
before=$failures
run_reconcile
check "exits zero" succeeded
check "retried it" deployed deploy-import.sh
check "stamps the reconcile pass" stamped reconcile
show_output_on_failure "$before"

new_case "deployed, the import service deployed before"
deployed_at_head
touch "$ROOT/mnt/fil-one/control/state/apps-import-service.sha256"
before=$failures
run_reconcile
check "exits zero" succeeded
check "applies the import service's firewall" deployed import-firewall.sh
check "and deploys nothing" only_deployed import-firewall.sh
show_output_on_failure "$before"

current="deployed, the import service deployed before, its firewall fails with the table loaded"
touch "$STUB_STATE/fail-import-firewall.sh" "$STUB_STATE/firewall-loaded"
before=$failures
run_reconcile
check "exits zero" succeeded
check "tried the firewall" deployed import-firewall.sh
check "warns" said "WARNING: the import service's firewall"
check "says the earlier table stays" said "the table loaded before stays in force"
check "leaves the service running" not_stopped
check "asks for no retry" test ! -e "$ROOT/mnt/fil-one/control/state/import-retry"
check "stamps the reconcile pass" stamped reconcile
show_output_on_failure "$before"

new_case "deployed, the import service deployed before, its firewall fails with no table"
deployed_at_head
touch "$ROOT/mnt/fil-one/control/state/apps-import-service.sha256" "$STUB_STATE/fail-import-firewall.sh"
before=$failures
run_reconcile
check "exits zero" succeeded
check "asks whether the table is loaded" deployed "import-firewall.sh loaded"
check "warns" said "stopping the import service so its port is not open to every address"
check "stops the service" stopped filone-import-service
check "leaves a retry for the next pass" test -e "$ROOT/mnt/fil-one/control/state/import-retry"
check "stamps the reconcile pass" stamped reconcile
show_output_on_failure "$before"

current="deployed, the import service's firewall fails with no table, the next pass"
rm -f "$STUB_STATE/fail-import-firewall.sh"
: >"$STUB_STATE/calls"
before=$failures
run_reconcile
check "exits zero" succeeded
check "runs the service's deploy, which loads the table and starts it" deployed deploy-import.sh
check "stops nothing" not_stopped
show_output_on_failure "$before"

new_case "deployed, the import service's firewall fails with no table and it cannot be stopped"
deployed_at_head
touch "$ROOT/mnt/fil-one/control/state/apps-import-service.sha256" \
  "$STUB_STATE/fail-import-firewall.sh" "$STUB_STATE/docker-stop-fails"
before=$failures
run_reconcile
check "exits non-zero" failed
check "says why" said "could not stop filone-import-service"
check "does not stamp the reconcile pass" eval '! stamped reconcile'
show_output_on_failure "$before"

new_case "deployed, both retries"
deployed_at_head
touch "$ROOT/mnt/fil-one/control/state/import-retry" "$ROOT/mnt/fil-one/control/state/rag-retry"
before=$failures
run_reconcile
check "exits zero" succeeded
check "retries Bucket Intelligence" deployed deploy-rag.sh
check "retries the import service" deployed deploy-import.sh
check "deploys no app" not_deployed deploy-apps.sh
show_output_on_failure "$before"

new_case "an apps deploy with an import retry pending"
bao_put ingot hilt_proof proof
touch_state="$ROOT/mnt/fil-one/control/state"
mkdir -p "$touch_state"
touch "$touch_state/import-retry"
before=$failures
run_reconcile
check "deploys the apps" deployed deploy-apps.sh
check "leaves the import service to the apps deploy" not_deployed deploy-import.sh
show_output_on_failure "$before"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
