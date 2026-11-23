#!/usr/bin/env bash
# Tests for helpers in scripts/host/lib.sh and lib/openbao.sh, run from any
# machine:
#
#   scripts/host/tests/lib.test.sh
#
# Starts with the check filone_init makes before it creates the state
# directory, on a node whose node.env says it is a mount point of its own.
#
# Covers moving OpenBao's store aside and back, on a node where the raft
# directory shares its parent's filesystem (dev, staging) and on one where it
# is a mount point of its own (prod/us-east-2's control/openbao dataset); the
# node.env values provision-apps.sh and deploy-apps.sh require for the
# apps, and the secrets they need in OpenBao; and the
# node.env placeholders deploy-apps.sh and deploy-platform.sh refuse.
#
# No real mount is made. Stub stat, mv, cp and install come first on PATH: stat
# reports a directory named in $STUB_STATE/mounts as on a device of its own,
# and mv refuses to rename one, with EBUSY's message, as Linux does. Every call
# is appended to $STUB_STATE/calls.
#
# Plain bash, written for the bash 3.2 macOS ships as well as for a current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
NODES="$(cd "$HERE/../../../nodes" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lib-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REAL_MV="$(command -v mv)"
REAL_CP="$(command -v cp)"
REAL_MKDIR="$(command -v mkdir)"
REAL_CHMOD="$(command -v chmod)"

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

BIN="$WORK/bin"
"$REAL_MKDIR" -p "$BIN"
export STUB_STATE REAL_MV REAL_CP REAL_MKDIR REAL_CHMOD

cat >"$BIN/stat" <<'STUB'
#!/usr/bin/env bash
# stat -c <format> <path>: %d is 2 for a path in $STUB_STATE/mounts, else 1.
echo "stat $*" >>"$STUB_STATE/calls"
[ "$1" = -c ] || exit 2
format="$2" path="$3"
[ -e "$path" ] || { echo "stat: cannot statx '$path': No such file or directory" >&2; exit 1; }
case "$format" in
  %d) if grep -qxF "$path" "$STUB_STATE/mounts" 2>/dev/null; then echo 2; else echo 1; fi ;;
  "%u %g %a") echo "0 0 700" ;;
  *) exit 2 ;;
esac
STUB

cat >"$BIN/mv" <<'STUB'
#!/usr/bin/env bash
echo "mv $*" >>"$STUB_STATE/calls"
args=()
for arg in "$@"; do [ "$arg" = -T ] || args+=("$arg"); done
if grep -qxF "${args[0]}" "$STUB_STATE/mounts" 2>/dev/null; then
  echo "mv: cannot move '${args[0]}' to '${args[1]}': Device or resource busy" >&2
  exit 1
fi
exec "$REAL_MV" "${args[@]}"
STUB

cat >"$BIN/cp" <<'STUB'
#!/usr/bin/env bash
echo "cp $*" >>"$STUB_STATE/calls"
[ ! -e "$STUB_STATE/cp-fails" ] || { echo "cp: No space left on device" >&2; exit 1; }
exec "$REAL_CP" "$@"
STUB

cat >"$BIN/install" <<'STUB'
#!/usr/bin/env bash
# install -d [-o uid] [-g gid] [-m mode] <dir>: owner ignored.
echo "install $*" >>"$STUB_STATE/calls"
mode=""
while [ "$#" -gt 1 ]; do
  case "$1" in
    -d) ;;
    -m) mode="$2"; shift ;;
    -o|-g) shift ;;
  esac
  shift
done
"$REAL_MKDIR" -p "$1"
[ -z "$mode" ] || "$REAL_CHMOD" "$mode" "$1"
STUB

cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
# docker inspect -f '{{.State.Running}}' <container>: true while
# $STUB_STATE/bao-running exists, else no such container.
# docker compose ... config: $STUB_STATE/compose.json.
# docker ps -a ...: $STUB_STATE/ps, one `<service> <state>` per line.
echo "docker $*" >>"$STUB_STATE/calls"
case "$1" in
  inspect)
    [ -e "$STUB_STATE/bao-running" ] || { echo "Error: No such object: ${*: -1}" >&2; exit 1; }
    echo true
    ;;
  compose) cat "$STUB_STATE/compose.json" ;;
  ps) cat "$STUB_STATE/ps" 2>/dev/null || true ;;
  *) exit 2 ;;
esac
STUB

"$REAL_CHMOD" +x "$BIN"/*
PATH="$BIN:$PATH"

# shellcheck source=../lib.sh
. "$SCRIPTS/lib.sh"

# --- Cases -------------------------------------------------------------------

new_case() {
  current="$1"
  CASE="$WORK/case$((++case_count))"
  STUB_STATE="$CASE/state"
  CONTROL="$CASE/control"
  "$REAL_MKDIR" -p "$STUB_STATE" "$CONTROL/openbao/raft"
  : >"$STUB_STATE/calls"
  echo store >"$CONTROL/openbao/vault.db"
  echo log >"$CONTROL/openbao/raft/raft.db"
}
case_count=0

as_mount() { echo "$CONTROL/openbao" >>"$STUB_STATE/mounts"; }
called() { grep -qE "$1" "$STUB_STATE/calls"; }
not_called() { ! called "$1"; }
holds_store() { # holds_store <dir> [vault.db contents]
  [ "$(cat "$1/vault.db" 2>/dev/null)" = "${2:-store}" ] &&
    [ "$(cat "$1/raft/raft.db" 2>/dev/null)" = log ]
}
is_empty_dir() { [ -d "$1" ] && [ -z "$(ls -A "$1")" ]; }

# Run a helper in a subshell, since die exits; status and stderr are kept.
run() {
  status=0
  (FILONE_CONTROL_DIR="$CONTROL" "$@") 2>"$CASE/stderr" || status=$?
}
said() { grep -qF -- "$1" "$CASE/stderr"; }

echo "==> moving the store aside"

new_case "raft directory on its parent's filesystem"
run move_bao_store_aside "$CONTROL/openbao.damaged-1"
check "succeeds" test "$status" -eq 0
check "renames the store" called "^mv -T $CONTROL/openbao $CONTROL/openbao.damaged-1\$"
check "copies nothing" not_called '^cp '
check "the destination holds the store" holds_store "$CONTROL/openbao.damaged-1"
check "leaves an empty raft directory" is_empty_dir "$CONTROL/openbao"
check "with the store's mode" test -n "$(find "$CONTROL/openbao" -maxdepth 0 -perm 700)"

new_case "raft directory that is a mount point"
as_mount
run move_bao_store_aside "$CONTROL/openbao.damaged-1"
check "succeeds" test "$status" -eq 0
check "does not rename the mount point" not_called "^mv .*$CONTROL/openbao "
check "the destination holds the store" holds_store "$CONTROL/openbao.damaged-1"
check "leaves the mount point empty" is_empty_dir "$CONTROL/openbao"

new_case "raft directory that is a mount point, copy fails"
as_mount
touch "$STUB_STATE/cp-fails"
run move_bao_store_aside "$CONTROL/openbao.damaged-1"
check "fails" test "$status" -ne 0
check "says the store is unchanged" said "is unchanged"
check "leaves the store where it was" holds_store "$CONTROL/openbao"
check "leaves no partial destination" test ! -e "$CONTROL/openbao.damaged-1"

new_case "destination already there"
as_mount
"$REAL_MKDIR" "$CONTROL/openbao.damaged-1"
run move_bao_store_aside "$CONTROL/openbao.damaged-1"
check "fails" test "$status" -ne 0
check "leaves the store where it was" holds_store "$CONTROL/openbao"

new_case "OpenBao still running"
as_mount
touch "$STUB_STATE/bao-running"
run move_bao_store_aside "$CONTROL/openbao.damaged-1"
check "fails" test "$status" -ne 0
check "says OpenBao is running" said "filone-openbao is running"
check "copies nothing" not_called '^cp '
check "leaves the store where it was" holds_store "$CONTROL/openbao"
check "leaves no destination" test ! -e "$CONTROL/openbao.damaged-1"

echo "==> a drill's rollback"

# The drill moves the store into its directory, a restore fills the raft
# directory with another, and the rollback puts the original back.
drill_then_restore() {
  "$REAL_MKDIR" -p "$CONTROL/drill"
  (FILONE_CONTROL_DIR="$CONTROL" move_bao_store_aside "$CONTROL/drill/openbao") 2>/dev/null
  echo restored >"$CONTROL/openbao/vault.db"
  "$REAL_MKDIR" -p "$CONTROL/openbao/raft"
  echo log >"$CONTROL/openbao/raft/raft.db"
}

new_case "rollback, raft directory on its parent's filesystem"
drill_then_restore
: >"$STUB_STATE/calls"
run move_dir_back "$CONTROL/openbao" "$CONTROL/drill/openbao" "$CONTROL/drill/openbao.restored"
check "succeeds" test "$status" -eq 0
check "renames the restored store aside" \
  called "^mv -T $CONTROL/openbao $CONTROL/drill/openbao.restored\$"
check "renames the original back" called "^mv -T $CONTROL/drill/openbao $CONTROL/openbao\$"
check "the original store is back" holds_store "$CONTROL/openbao"
check "the restored store is kept" holds_store "$CONTROL/drill/openbao.restored" restored

new_case "rollback, raft directory that is a mount point"
as_mount
drill_then_restore
run move_dir_back "$CONTROL/openbao" "$CONTROL/drill/openbao" "$CONTROL/drill/openbao.restored"
check "succeeds" test "$status" -eq 0
check "does not rename the mount point" not_called "^mv .*$CONTROL/openbao "
check "the original store is back" holds_store "$CONTROL/openbao"
check "the restored store is kept" holds_store "$CONTROL/drill/openbao.restored" restored
check "the copy moved aside is kept under another name" \
  holds_store "$CONTROL/drill/openbao.rolled-back"
check "a second run finds nothing to put back" test ! -e "$CONTROL/drill/openbao"

# The rollback script simulate-openbao-loss.sh writes calls the helper above.
current="simulate-openbao-loss.sh"
# shellcheck disable=SC2016 # the literal line the heredoc holds
check "its rollback script puts the store back with move_dir_back" \
  grep -qF 'move_dir_back $raft_dir $drill_dir/openbao $drill_dir/openbao.restored' \
  "$SCRIPTS/simulate-openbao-loss.sh"

echo "==> containers that should be running"

# A project with two long-running services and a one-shot, as the platform
# project's postgres and postgres-init are.
compose_json='{"services": {
  "caddy": {"restart": "unless-stopped"},
  "postgres": {"restart": "unless-stopped"},
  "postgres-init": {"restart": "no"},
  "unset-restart": {}
}}'

# description | the containers Docker lists, `service state` separated by
# commas, or - for none | the services passed to check, or - for every one |
# what stopped_services prints, `service state` separated by commas, or - for
# nothing
while IFS='|' read -r description containers services expected; do
  new_case "stopped_services, $description"
  printf '%s\n' "$compose_json" >"$STUB_STATE/compose.json"
  [ "$containers" = - ] || tr ',' '\n' <<<"$containers" >"$STUB_STATE/ps"
  [ "$services" != - ] || services=""
  [ "$expected" != - ] || expected=""
  # shellcheck disable=SC2086 # one service name per word
  output="$(FILONE_NODE_DIR=nodes/test stopped_services platform $services 2>"$CASE/stderr")" ||
    output="failed: $(cat "$CASE/stderr")"
  check "prints '${expected}'" test "$(tr '\n' ',' <<<"$output" | sed 's/,$//')" = "$expected"
done <<'CASES'
all running|caddy running,postgres running,postgres-init exited|-|-
one stopped by hand|caddy exited,postgres running,postgres-init exited|-|caddy exited
one removed|postgres running|-|caddy missing
no container at all|-|-|caddy missing,postgres missing
one restarting|caddy restarting,postgres running|-|-
one created and never started|caddy created,postgres running|-|caddy created
a stopped copy next to a running one|caddy exited,caddy running,postgres running|-|-
only the services asked about|caddy exited,postgres exited|postgres|postgres exited
CASES

new_case "stopped_services, a service the project does not define"
printf '%s\n' "$compose_json" >"$STUB_STATE/compose.json"
run stopped_services platform ingot
check "fails" test "$status" -ne 0

new_case "stopped_services, the containers it lists"
printf '%s\n' "$compose_json" >"$STUB_STATE/compose.json"
FILONE_NODE_DIR=nodes/test stopped_services apps >/dev/null
check "are the project's, by its compose label" \
  called "^docker ps -a --filter label=com.docker.compose.project=filone-apps "
check "leave out one-off containers" called " --filter label=com.docker.compose.oneoff=False "

current="reconcile.sh"
# shellcheck disable=SC2016 # the literal line grep looks for
check "checks the platform's containers" \
  grep -qx '  stopped="$(stopped_services platform)"' "$SCRIPTS/reconcile.sh"
# shellcheck disable=SC2016 # the literal line grep looks for
check "checks the Piris' and Ingot's containers" \
  grep -qx '  stopped="$(stopped_services apps $core_services)"' "$SCRIPTS/reconcile.sh"
# shellcheck disable=SC2016 # the literal line grep looks for
check "leaves token renewal to the platform deploy while OpenBao is down" \
  grep -qx 'if container_running "$FILONE_BAO_CONTAINER"; then' "$SCRIPTS/reconcile.sh"
# shellcheck disable=SC2016 # the literal line grep looks for
check "deploys the apps after a failed platform deploy" \
  grep -qx '  if ! "$FILONE_CHECKOUT/scripts/host/deploy-platform.sh"; then' "$SCRIPTS/reconcile.sh"
current="reset-apps.sh"
# Before the apps are stopped, so no pass can start them again.
check "disables the reconcile timer before it stops the apps" \
  test "$(grep -n 'systemctl disable --now filone-reconcile.timer' "$SCRIPTS/reset-apps.sh" | cut -d: -f1)" \
  -lt "$(grep -n '^if ! stop_apps' "$SCRIPTS/reset-apps.sh" | cut -d: -f1)"
check "stops a reconcile timer that is active but not enabled, before it stops the apps" \
  test "$(grep -n 'systemctl stop filone-reconcile.timer' "$SCRIPTS/reset-apps.sh" | cut -d: -f1)" \
  -lt "$(grep -n '^if ! stop_apps' "$SCRIPTS/reset-apps.sh" | cut -d: -f1)"

echo "==> node.env values the apps need"

FILONE_NODE_DIR=nodes/test
bao_has() { [ -e "$STUB_STATE/bao/$1/$2" ]; }
# set_inputs <budget> <endpoint> <path>: an endpoint of - leaves both object
# storage settings unset, as on a node whose Piris keep their blobs locally.
set_inputs() {
  # SC2034: read by require_apps_inputs.
  # shellcheck disable=SC2034
  INGOT_LOCAL_BLOB_MAX_BYTES="$1"
  if [ "$2" = - ]; then
    unset PIRI_S3_ENDPOINT PIRI_S3_PATH
  else
    # shellcheck disable=SC2034
    PIRI_S3_ENDPOINT="$2" PIRI_S3_PATH="$3"
  fi
}

# description | budget | endpoint | path | the name the refusal gives, or -
# for a pass
while IFS='|' read -r description budget endpoint path refused; do
  new_case "require_apps_inputs, $description"
  set_inputs "$budget" "$endpoint" "$path"
  run require_apps_inputs
  if [ "$refused" = - ]; then
    check "passes" test "$status" -eq 0
  else
    # shellcheck disable=SC2016 # expanded by eval
    check "refuses, naming $refused" eval '[ "$status" -ne 0 ] && said "$refused"'
  fi
done <<'CASES'
budget 0|0|-||INGOT_LOCAL_BLOB_MAX_BYTES
budget empty||-||INGOT_LOCAL_BLOB_MAX_BYTES
budget with a unit|5GiB|-||INGOT_LOCAL_BLOB_MAX_BYTES
budget negative|-1|-||INGOT_LOCAL_BLOB_MAX_BYTES
budget set, no object storage|1000|-||-
endpoint empty|1000||bucket/piri-0/|PIRI_S3_ENDPOINT
path empty|1000|https://objects.example||PIRI_S3_PATH
object storage configured|1000|https://objects.example|bucket/piri-0/|-
CASES

new_case "node.env without object storage"
(unset PIRI_S3_ENDPOINT; ! piri_uses_s3) && status=0 || status=1
check "is not a node whose Piris use it" test "$status" -eq 0

new_case "object storage settings present but empty"
set_inputs 1000 "" ""
check "is a node whose Piris use it" piri_uses_s3

# description | object storage, yes or no | the external fields OpenBao holds,
# or - | the field the refusal names, or - for a pass
while IFS='|' read -r description object_storage stored refused; do
  new_case "require_apps_secrets, $description"
  if [ "$object_storage" = yes ]; then
    set_inputs 1000 https://objects.example bucket/piri-0/
  else
    set_inputs 1000 -
  fi
  "$REAL_MKDIR" -p "$STUB_STATE/bao/external"
  if [ "$stored" != - ]; then
    for field in $stored; do : >"$STUB_STATE/bao/external/$field"; done
  fi
  run require_apps_secrets
  if [ "$refused" = - ]; then
    check "passes" test "$status" -eq 0
  else
    # shellcheck disable=SC2016 # expanded by eval
    check "refuses, naming $refused" eval '[ "$status" -ne 0 ] && said "external#$refused"'
  fi
done <<'CASES'
no object storage, nothing stored|no|-|chain_rpc_token
no object storage, chain.love token stored|no|chain_rpc_token|-
object storage, access key id missing|yes|chain_rpc_token piri_s3_secret_access_key|piri_s3_access_key_id
object storage, secret key missing|yes|chain_rpc_token piri_s3_access_key_id|piri_s3_secret_access_key
object storage, chain.love token missing|yes|piri_s3_access_key_id piri_s3_secret_access_key|chain_rpc_token
object storage, all three stored|yes|chain_rpc_token piri_s3_access_key_id piri_s3_secret_access_key|-
CASES

for node in dev staging/eu-central-3 prod/us-east-2; do
  current="$node"
  # shellcheck disable=SC1090
  check "passes require_apps_inputs" \
    bash -c "set -a; . '$NODES/$node/node.env'; set +a; . '$SCRIPTS/lib.sh'; require_apps_inputs"
done

current="provision-apps.sh"
# Before its first step, ahead of every prompt and the deploy.
check "checks the apps' inputs before it asks for anything" \
  test "$(grep -nx 'require_apps_inputs' "$SCRIPTS/provision-apps.sh" | cut -d: -f1)" \
  -lt "$(grep -n '^# --- 1\. ' "$SCRIPTS/provision-apps.sh" | cut -d: -f1)"
current="provision-platform.sh"
check "leaves the apps' inputs and secrets to provision-apps.sh" \
  bash -c "! grep -q 'require_apps_inputs\|piri_s3_\|chain_rpc_token' '$SCRIPTS/provision-platform.sh'"
current="deploy-apps.sh"
check "checks the apps' inputs" grep -qx 'require_apps_inputs' "$SCRIPTS/deploy-apps.sh"
check "refuses a deploy without the apps' secrets" \
  grep -qx 'require_apps_secrets' "$SCRIPTS/deploy-apps.sh"
current="prod/us-east-2"
# shellcheck disable=SC1091
check "is a node whose Piris use object storage" \
  bash -c ". '$NODES/prod/us-east-2/node.env'; [ -n \"\${PIRI_S3_ENDPOINT+set}\" ]"
template="$NODES/prod/us-east-2/apps/config/piri/piri-base-config.toml.tpl"
for name in PIRI_S3_ENDPOINT PIRI_S3_PATH PIRI_S3_ACCESS_KEY_ID PIRI_S3_SECRET_ACCESS_KEY; do
  check "its Piri base config renders $name" grep -qF "\${$name}" "$template"
done

echo "==> the state directory's mount"

# description | FILONE_STATE_DIR_IS_MOUNT, or - to leave it unset | the state
# directory: mount, plain or absent | what the refusal says, or - for a pass
while IFS='|' read -r description setting state_dir refused; do
  new_case "require_state_mount, $description"
  if [ "$setting" = - ]; then
    unset FILONE_STATE_DIR_IS_MOUNT
  else
    # SC2034: read by require_state_mount.
    # shellcheck disable=SC2034
    FILONE_STATE_DIR_IS_MOUNT="$setting"
  fi
  FILONE_STATE_DIR="$CONTROL/state"
  case "$state_dir" in
    mount)
      "$REAL_MKDIR" "$FILONE_STATE_DIR"
      echo "$FILONE_STATE_DIR" >>"$STUB_STATE/mounts"
      ;;
    plain) "$REAL_MKDIR" "$FILONE_STATE_DIR" ;;
  esac
  run require_state_mount
  if [ "$refused" = - ]; then
    check "passes" test "$status" -eq 0
  else
    # shellcheck disable=SC2016 # expanded by eval
    check "refuses, saying '$refused'" eval '[ "$status" -ne 0 ] && said "$refused"'
  fi
done <<'CASES'
required, state directory a mount point|true|mount|-
required, state directory on the control directory's filesystem|true|plain|is not a mount point
required, state directory missing|true|absent|is not a mount point
not required, state directory on the control directory's filesystem|false|plain|-
left out, state directory missing|-|absent|-
empty|||must be true or false
not true or false|yes|mount|must be true or false
CASES
unset FILONE_STATE_DIR_IS_MOUNT FILONE_STATE_DIR

current="filone_init"
# shellcheck disable=SC2016 # the literal line grep looks for
check "checks the state directory's mount before it creates the directory" \
  test "$(grep -nx '  require_state_mount' "$SCRIPTS/lib.sh" | cut -d: -f1)" \
  -lt "$(grep -n '^  mkdir -p "\$FILONE_STATE_DIR"' "$SCRIPTS/lib.sh" | cut -d: -f1)"

echo "==> node.env placeholders"

# Each require_configured line in the deploy scripts, run against each node's
# node.env. Every node passes every one now; a node that commits a placeholder
# again is checked with refuse, and the values it has set named after it.
refusals="$(grep -hE '^ *require_configured ' "$SCRIPTS/deploy-apps.sh" "$SCRIPTS/deploy-platform.sh" |
  sed 's/^ *//')"
check_placeholders() { # check_placeholders <node> pass|refuse [name that passes...]
  local node="$1" default="$2" line result want name
  shift 2
  current="$node"
  while read -r line; do
    want="$default"
    for name in "$@"; do
      [[ "$line" != "require_configured $name "* ]] || want=pass
    done
    # deploy-platform.sh checks the Grafana values only on a node that ships
    # its own telemetry, which staging does not.
    if [[ "$line" == *GRAFANA_* ]] && ! grep -q '^GRAFANA_LOGS_URL=' "$NODES/$node/node.env"; then
      continue
    fi
    result=pass
    # shellcheck disable=SC1090
    (set -a; . "$NODES/$node/node.env"; set +a; FILONE_NODE_DIR="$NODES/$node"; eval "$line") \
      2>/dev/null || result=refuse
    check "${line#require_configured }: $want" test "$result" = "$want"
  done <<<"$refusals"
}
check_placeholders dev pass
check_placeholders staging/eu-central-3 pass
check_placeholders prod/us-east-2 pass

# No committed node.env holds a placeholder, so each line is also run with its
# value set to the placeholder it names.
current="a value left at its placeholder"
while read -r _ name placeholder; do
  result=pass
  (FILONE_NODE_DIR="$NODES/dev"; printf -v "$name" '%s' "$placeholder"; require_configured "$name" "$placeholder") \
    2>/dev/null || result=refuse
  check "$name $placeholder: refuse" test "$result" = refuse
done <<<"$refusals"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
