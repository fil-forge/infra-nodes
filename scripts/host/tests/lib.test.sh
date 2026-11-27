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
# apps, and the secrets they need in OpenBao; the
# node.env placeholders deploy-apps.sh and deploy-platform.sh refuse; and the
# import service's helpers: its placeholders, address, password file, DSN
# check and site secret file, the hash a changed render forgets, the container
# removed when a setting is a placeholder again, and the key source its compose
# definition gives it.
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
check "refuses the prod stage without --production" \
  grep -q "refusing to reset the apps on stage 'prod' without --production" "$SCRIPTS/reset-apps.sh"
check "always asks for the confirmation on prod" \
  grep -q -- '--yes is refused with --production' "$SCRIPTS/reset-apps.sh"
# Before the apps are stopped, so a catalog log the reset cannot empty stops it
# with nothing changed.
check "looks at Ingot's own catalog log filesystem before it stops the apps" \
  test "$(grep -n 'Destination "/data/segments"' "$SCRIPTS/reset-apps.sh" | cut -d: -f1)" \
  -lt "$(grep -n '^if ! stop_apps' "$SCRIPTS/reset-apps.sh" | cut -d: -f1)"

current="is_app_data_dir"
refuses() { ! "$@"; }
for dir in /mnt/fil-one/piri /mnt/fil-one/piri-0 /mnt/data/fil-one/piri/piri-12 \
  /var/lib/fil-one/ingot /mnt/data/fil-one/ingot/blobs; do
  check "accepts $dir" is_app_data_dir "$dir"
done
for dir in /mnt/data/fil-one/control /mnt/data/fil-one/ingot/segments /mnt/data/fil-one/blobs \
  /mnt/data/fil-one/piri/blobs /mnt/fil-one/piri-x /mnt/fil-one; do
  check "refuses $dir" refuses is_app_data_dir "$dir"
done

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

current="piri_did"
# piri_did <suffix> <url> <service>: the DID of a service, in a subshell since
# die exits.
piri_did_of() {
  (
    FILONE_NODE="test-node"
    PIRI_HOSTNAME_SUFFIX="$1" PIRI_PUBLIC_URL="$2"
    piri_did "$3"
  ) 2>/dev/null
}
check "a Piri named by the hostname suffix" \
  test "$(piri_did_of eu-central-3.staging.example.com '' piri-1)" = did:web:piri-1.eu-central-3.staging.example.com
check "a single Piri with its own public URL" \
  test "$(piri_did_of '' https://piri.example.com piri)" = did:web:piri.example.com
check "a trailing slash is not part of the DID" \
  test "$(piri_did_of '' https://piri.example.com/ piri)" = did:web:piri.example.com
check "the host is lower case" \
  test "$(piri_did_of '' https://Piri.Example.com piri)" = did:web:piri.example.com
check "a port is percent-encoded" \
  test "$(piri_did_of '' https://piri.example.com:8443 piri)" = did:web:piri.example.com%3A8443
check "the default port is left out" \
  test "$(piri_did_of '' https://piri.example.com:443 piri)" = did:web:piri.example.com
for url in http://piri.example.com https://piri.example.com/piri 'https://piri.example.com?x=1' https://user@piri.example.com https://; do
  result=pass
  piri_did_of '' "$url" piri >/dev/null || result=refuse
  check "$url: refuse" test "$result" = refuse
done

echo "==> the import service"

# Each case runs in a subshell with the node's node.env loaded, as filone_init
# loads it, and the node directory copied so versions.env can be edited.
import_case() { # import_case <name>
  new_case "$1"
  "$REAL_CP" -R "$NODES/prod/us-east-2" "$CASE/node"
}
placeholders() { # placeholders [NAME=value...]: what import_service_placeholders prints
  # shellcheck disable=SC1091
  (set -a; . "$CASE/node/node.env"; set +a; FILONE_NODE_DIR="$CASE/node"
    for assignment in "$@"; do export "${assignment?}"; done
    import_service_placeholders)
}
configured=(IMPORT_SERVICE_ALLOWED_CLIENTS=box-1 IMPORT_SERVICE_LEASE_HOLDER=site-a
  IMPORT_SERVICE_S3_BUCKET=packs IMPORT_SERVICE_RECOVERY_PUBLIC_KEY=00ff)
has_line() { grep -qxF -- "$1" <<<"$2"; }
lacks_line() { ! has_line "$@"; }
pin_image() { # pin_image <reference>
  grep -v '^IMPORT_SERVICE_IMAGE=' "$CASE/node/apps/versions.env" >"$CASE/versions.env"
  echo "IMPORT_SERVICE_IMAGE=$1" >>"$CASE/versions.env"
  "$REAL_MV" "$CASE/versions.env" "$CASE/node/apps/versions.env"
}

import_case "prod/us-east-2 as committed"
check "names nothing" test -z "$(placeholders)"

import_case "every setting and the pin filled"
pin_image "registry.example/import:v1@sha256:$(printf '%064d' 0)"
check "names nothing" test -z "$(placeholders "${configured[@]}")"

import_case "one setting left"
pin_image "registry.example/import:v1@sha256:$(printf '%064d' 0)"
check "names it" test "$(placeholders "${configured[@]}" IMPORT_SERVICE_LEASE_HOLDER=PLACEHOLDER)" = \
  IMPORT_SERVICE_LEASE_HOLDER
check "names an empty one too" test "$(placeholders "${configured[@]}" IMPORT_SERVICE_S3_BUCKET=)" = \
  IMPORT_SERVICE_S3_BUCKET

import_case "pin left"
pin_image PLACEHOLDER
check "names the image" test "$(placeholders "${configured[@]}")" = IMPORT_SERVICE_IMAGE

# The deploy that waits on Piri and Ingot leaves the service to deploy-import.sh.
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  import_case "the apps deploy's services"
  core="$(FILONE_NODE_DIR="$CASE/node" FILONE_NODE=prod/us-east-2 apps_core_services)"
  check "leave the import service out" lacks_line import-service "$core"
  check "keep Ingot" has_line ingot "$core"
  check "keep the Piri" has_line piri-0 "$core"
else
  echo "  skip the apps deploy's services: no docker compose here"
fi

# deploy-import.sh's address, password file, DSN and recovery key checks. Documentation
# networks and made-up values only.
new_case "the import service's address on the filone network"
check "is the last usable address of a /16" \
  test "$(import_service_address 172.18.0.0/16)" = 172.18.255.254
check "is the last usable address of a /30" \
  test "$(import_service_address 192.0.2.0/30)" = 192.0.2.2
check "refuses a network with no room" eval '! import_service_address 192.0.2.0/31 2>/dev/null'
check "refuses an IPv6 network" eval '! import_service_address 2001:db8::/64 2>/dev/null'
check "refuses something that is no network" eval '! import_service_address filone 2>/dev/null'

new_case "the ledger's password file line"
check "matches any host, port, database and user" \
  test "$(import_pgpass_line 'plain')" = '*:*:*:*:plain'
check "escapes a colon and a backslash" \
  test "$(import_pgpass_line 'a:b\c')" = '*:*:*:*:a\:b\\c'

new_case "a ledger DSN carrying a password"
for dsn in 'host=db.example dbname=ledger password=x' 'host=db.example PASSWORD=x' \
  'postgresql://import:x@db.example/ledger' 'postgresql://db.example/ledger?password=x'; do
  check "is refused: $dsn" ledger_dsn_has_password "$dsn"
done
for dsn in 'host=db.example dbname=ledger user=import' 'postgresql://import@db.example/ledger' \
  'postgresql://import@db.example:5432/ledger' 'postgresql://db.example:5432/ledger'; do
  check "is accepted without one: $dsn" eval "! ledger_dsn_has_password '$dsn'"
done

new_case "the import service's recovery public key"
for key in 00ff 00FFab; do
  check "is accepted: $key" import_recovery_key_is_hex "$key"
done
for key in '' 0ff 00f 00fg '00 ff' 0x00ff; do
  check "is refused: '$key'" eval "! import_recovery_key_is_hex '$key'"
done

# The site secret file: the base64 OpenBao holds, which the service decodes
# itself, with the service's own refusals of anything that is not strict base64
# of exactly 32 bytes once surrounding whitespace is stripped. Made-up secrets
# only. Each case runs in a subshell, as die exits.
site_secret_case() { # site_secret_case <name>
  new_case "$1"
  SECRETS="$CASE/secrets"
  "$REAL_MKDIR" -p "$SECRETS"
}
write_site_secret() { # write_site_secret <base64>: import_site_secret_file's status
  site_status=0
  (FILONE_SECRETS_DIR="$SECRETS"
    import_site_secret_file filone/import-service#site_secret "$SECRETS/site-secret" "$1") \
    >"$CASE/stdout" 2>"$CASE/stderr" || site_status=$?
}
no_temp_left() { test -z "$(find "$SECRETS" -name '.write.*')"; }
says_nothing_of() { ! grep -qF -- "$1" "$CASE/stdout" "$CASE/stderr"; }
# The service's own check of a site secret file, as its image reads one: the
# 32 bytes, or a failure.
service_reads() { # service_reads <file>
  python3 -c '
import base64, sys
with open(sys.argv[1], "rb") as fobj:
    secret = base64.b64decode(fobj.read().strip(), validate=True)
sys.exit(len(secret) != 32)
' "$1"
}
refused_unwritten() { # refused_unwritten <value>: the checks every refusal passes
  check "is refused" test "$site_status" -ne 0
  check "names the field" grep -q 'filone/import-service#site_secret' "$CASE/stderr"
  check "does not print the value" says_nothing_of "$1"
  check "writes no file" test ! -e "$SECRETS/site-secret"
  check "leaves no temp file" no_temp_left
}
secret_a="$(printf 'a%.0s' $(seq 32) | base64)"
secret_b="$(printf 'b%.0s' $(seq 32) | base64)"

site_secret_case "a site secret, first written"
write_site_secret "$secret_a"
check "reports the change" test "$site_status" -eq 0
check "holds the base64 OpenBao holds, with a newline" \
  test "$(cat "$SECRETS/site-secret")" = "$secret_a" -a "$(tail -c 1 "$SECRETS/site-secret" | od -An -c | tr -d ' ')" = '\n'
check "is a file the service reads" service_reads "$SECRETS/site-secret"
check "is read-only to its owner alone" test -n "$(find "$SECRETS/site-secret" -perm 400)"
check "leaves no temp file" no_temp_left
write_site_secret "$secret_a"
check "reports no change when written again" test "$site_status" -eq 1
check "leaves no temp file then either" no_temp_left
write_site_secret "$secret_b"
check "reports a changed secret as a change" test "$site_status" -eq 0
check "holds the changed secret" test "$(cat "$SECRETS/site-secret")" = "$secret_b"

site_secret_case "a site secret with whitespace around the base64"
write_site_secret " $secret_a
"
check "is accepted" test "$site_status" -eq 0
check "is written without it" test "$(cat "$SECRETS/site-secret")" = "$secret_a"
write_site_secret "$secret_a"
check "is the same file as the value without it" test "$site_status" -eq 1

# A secret written as hex is valid base64 too, of 48 bytes, so it is refused
# rather than read as some other secret.
for length in 31 33 48; do
  site_secret_case "a site secret of $length bytes"
  value="$(printf 'c%.0s' $(seq "$length") | base64)"
  write_site_secret "$value"
  refused_unwritten "$value"
  check "says why" grep -q 'exactly 32 bytes' "$CASE/stderr"
done

site_secret_case "a site secret written as hex"
hex="$(printf 'e%.0s' $(seq 64))"
write_site_secret "$hex"
refused_unwritten "$hex"
check "says a hex secret decodes to 48 bytes" grep -q 'hex secret decodes' "$CASE/stderr"

site_secret_case "a site secret that is not base64"
write_site_secret 'not base64 at all!'
refused_unwritten 'not base64 at all!'
check "says why" grep -q 'not base64' "$CASE/stderr"

# Each of these decodes to 32 bytes with a lenient decoder, and the service's
# strict one refuses it.
site_secret_case "a site secret in URL-safe base64"
urlsafe="$(printf '\373%.0s' $(seq 32) | base64 | tr '+/' '-_')"
write_site_secret "$urlsafe"
refused_unwritten "$urlsafe"

site_secret_case "a site secret without its padding"
write_site_secret "${secret_a%=}"
refused_unwritten "${secret_a%=}"

site_secret_case "a site secret wrapped over two lines"
wrapped="${secret_a:0:20}
${secret_a:20}"
write_site_secret "$wrapped"
refused_unwritten "${secret_a:0:20}"

site_secret_case "a changed site secret, replacing the file the last deploy wrote"
write_site_secret "$secret_a"
STATE="$CASE/state-dir"
"$REAL_MKDIR" -p "$STATE"
echo recorded >"$STATE/apps-import-service.sha256"
site_status=0
(FILONE_SECRETS_DIR="$SECRETS" FILONE_STATE_DIR="$STATE" forget_hash_on_change apps-import-service \
  import_site_secret_file filone/import-service#site_secret "$SECRETS/site-secret" "$secret_b") ||
  site_status=$?
check "reports the change" test "$site_status" -eq 0
check "forgets the recorded hash, so the service is recreated" \
  test ! -e "$STATE/apps-import-service.sha256"

# A run that writes one changed secret and dies before the next leaves the
# recorded hash gone, so the retry, which reads that file as unchanged, still
# recreates the service. true and false stand in for a render that changed its
# file and one that did not: write_secret_file itself needs root to write the
# 0400 file it creates.
render_case() { # render_case <name> <command>: forget_hash_on_change's status
  new_case "$1"
  STATE="$CASE/state-dir"
  "$REAL_MKDIR" -p "$STATE"
  echo recorded >"$STATE/apps-import-service.sha256"
  render_status=0
  (FILONE_STATE_DIR="$STATE" forget_hash_on_change apps-import-service "$2") ||
    render_status=$?
}

render_case "a render that changes a file" true
check "reports the change" test "$render_status" -eq 0
check "forgets the recorded hash at once" test ! -e "$STATE/apps-import-service.sha256"

render_case "a render that changes nothing" false
check "reports no change" test "$render_status" -eq 1
check "keeps the recorded hash" test -e "$STATE/apps-import-service.sha256"

# A hash that cannot be removed, here through an rm that fails as it would on
# a read-only state directory, would leave a changed render looking unchanged.
# The call sits in an if, as it does inside mark, where errexit is off, so only
# an exit stops the run.
new_case "a render that changes a file, with the hash not removable"
STATE="$CASE/state-dir"
"$REAL_MKDIR" -p "$STATE"
echo recorded >"$STATE/apps-import-service.sha256"
render_status=0
(rm() { return 1; }
if FILONE_STATE_DIR="$STATE" forget_hash_on_change apps-import-service true; then :; fi
touch "$CASE/continued") 2>"$CASE/stderr" || render_status=$?
check "stops the run" test "$render_status" -ne 0
check "goes no further" test ! -e "$CASE/continued"
check "says why" grep -q 'could not forget' "$CASE/stderr"

# A docker stand-in for import_service_remove: inspect succeeds for a container
# named in $STUB_STATE/containers and otherwise answers as Docker does for a
# missing container, unless $STUB_STATE/docker-down makes it answer as a CLI
# that cannot reach the daemon. Every call is logged.
remove_service() {
  status=0
  (docker() {
    echo "docker $*" >>"$STUB_STATE/calls"
    if [ -e "$STUB_STATE/docker-down" ]; then
      echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2
      return 1
    fi
    case "$1" in
      inspect)
        grep -qxF "${*: -1}" "$STUB_STATE/containers" 2>/dev/null && return 0
        echo "Error: No such container: ${*: -1}" >&2
        return 1
        ;;
      rm) return 0 ;;
      *) return 1 ;;
    esac
  }
  import_service_remove filone-import-service) >"$CASE/stdout" 2>"$CASE/stderr" || status=$?
}

new_case "settings back to a placeholder, with the service running"
echo filone-import-service >"$STUB_STATE/containers"
remove_service
check "succeeds" test "$status" -eq 0
check "inspects it as a container" called '^docker inspect --type container filone-import-service$'
check "removes the container" called '^docker rm -f filone-import-service$'
check "does not claim it is running" eval "! grep -q 'still runs' '$CASE/stdout'"
check "says what it removes" grep -q 'removing filone-import-service' "$CASE/stdout"

new_case "settings back to a placeholder, with no container"
remove_service
check "succeeds" test "$status" -eq 0
check "removes nothing" not_called '^docker rm'

new_case "settings back to a placeholder, with the Docker daemon not answering"
touch "$STUB_STATE/docker-down"
remove_service
check "fails" test "$status" -ne 0
check "removes nothing" not_called '^docker rm'
check "says why" grep -q 'could not ask Docker' "$CASE/stderr"

# container_exists tells a missing container from a daemon that did not answer.
exists_status() { # exists_status: container_exists's status under the stub above
  status=0
  (docker() {
    if [ -e "$STUB_STATE/docker-down" ]; then
      echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2
      return 1
    fi
    grep -qxF "${*: -1}" "$STUB_STATE/containers" 2>/dev/null && return 0
    echo "Error: No such container: ${*: -1}" >&2
    return 1
  }
  container_exists filone-import-service) 2>/dev/null || status=$?
}

new_case "container_exists"
exists_status
check "returns 1 for no such container" test "$status" -eq 1
echo filone-import-service >"$STUB_STATE/containers"
exists_status
check "returns 0 for a container" test "$status" -eq 0
touch "$STUB_STATE/docker-down"
exists_status
check "returns 2 when the daemon does not answer" test "$status" -eq 2

current="deploy-import.sh"
# shellcheck disable=SC2016 # the literal line deploy-import.sh holds
check "removes the service while a setting is a placeholder" \
  grep -qxF '  import_service_remove "$CONTAINER"' "$SCRIPTS/deploy-import.sh"
check "renders every secret through forget_hash_on_change" \
  test "$(grep -cE '^mark rendered (write_secret_file|render_template)' \
    "$SCRIPTS/deploy-import.sh")" -eq 0
# shellcheck disable=SC2016 # the literal line deploy-import.sh holds
check "defines render() through forget_hash_on_change" \
  grep -qxF 'render() { mark rendered forget_hash_on_change "$hash_name" "$@"; }' \
  "$SCRIPTS/deploy-import.sh"
check "defines render() once" \
  test "$(grep -cE '^render\(\)' "$SCRIPTS/deploy-import.sh")" -eq 1
check "renders all six files that way" \
  test "$(grep -cE '^render (write_secret_file|render_template) ' "$SCRIPTS/deploy-import.sh")" -eq 6
check "renders the site secret that way too" \
  test "$(grep -cE '^render import_site_secret_file ' "$SCRIPTS/deploy-import.sh")" -eq 1
# shellcheck disable=SC2016 # the literal line deploy-import.sh holds
check "renders the site secret before giving the files to the service's user" \
  test "$(grep -nE '^render import_site_secret_file ' "$SCRIPTS/deploy-import.sh" | cut -d: -f1)" \
    -lt "$(grep -nE '^chown "\$SERVICE_UID' "$SCRIPTS/deploy-import.sh" | cut -d: -f1)"
check "reads no key service login" \
  eval "! grep -qE 'keys_role_id|keys_secret_id|KEYS_ADDR' '$SCRIPTS/deploy-import.sh'"

current="the import service's compose definition"
IMPORT_COMPOSE="$NODES/prod/us-east-2/apps/compose.yml"
IMPORT_ENV_TEMPLATE="$NODES/prod/us-east-2/apps/templates/import-service.env.tpl"
check "points the service at the rendered site secret" \
  grep -qxF '      IST1_PACK_SITE_SECRET: /run/import/site-secret' "$IMPORT_COMPOSE"
check "sets no OpenBao key source, since the service takes exactly one" \
  eval "! grep -q 'IST1_PACK_OPENBAO_' '$IMPORT_COMPOSE' '$IMPORT_ENV_TEMPLATE'"
mounts_read_only() {
  grep -A3 -F 'source: /run/fil-one/secrets/import-service' "$IMPORT_COMPOSE" |
    grep -qF 'read_only: true'
}
check "mounts the secrets directory read-only" mounts_read_only
check "points libpq at the RDS roots it mounts" \
  grep -qxF '      PGSSLROOTCERT: /etc/import-service/rds-us-east-2-bundle.pem' "$IMPORT_COMPOSE"
check "mounts the RDS roots read-only" \
  grep -qxF '      - ./config/import-service/rds-us-east-2-bundle.pem:/etc/import-service/rds-us-east-2-bundle.pem:ro' "$IMPORT_COMPOSE"
check "commits the RDS roots it mounts" \
  grep -q 'Amazon RDS us-east-2' <(openssl crl2pkcs7 -nocrl -certfile "$NODES/prod/us-east-2/apps/config/import-service/rds-us-east-2-bundle.pem" | openssl pkcs7 -print_certs -noout)

current="deploy-apps.sh"
# shellcheck disable=SC2016 # the literal line deploy-apps.sh holds
check "hands the import service to deploy-import.sh, outside its own success" \
  grep -qxF '"$SCRIPT_DIR/deploy-import.sh" || true' "$SCRIPTS/deploy-apps.sh"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
