#!/usr/bin/env bash
# Tests for scripts/host/report-pool-health.sh, run from any machine:
#
#   scripts/host/tests/report-pool-health.test.sh
#
# The script runs as root and reads the pool through `zpool status`. Here a
# stub zpool answers with JSON from a file in the case's state directory, in the
# shape OpenZFS 2.4's `zpool status -j --json-int` prints, and appends every
# call to a log. The script and lib.sh are copied into a temporary directory
# with /etc/fil-one, /run/fil-one and /mnt moved under the case's own root, and
# stub id, stat and install commands stand in for root, a mounted control
# volume and root ownership. Nothing outside the temporary directory changes.
#
# Plain bash plus jq, which the script needs itself, and written for the bash
# 3.2 macOS ships as well as for a current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
REAL_INSTALL="$(command -v install)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/report-pool-health-test.XXXXXX")"
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

  # A file zpool-fails makes the call fail, as zpool does when the module is
  # not loaded or the option is unknown to an older release.
  cat >"$bin/zpool" <<'STUB'
#!/usr/bin/env bash
echo "zpool $*" >>"$STUB_STATE/calls"
[ -e "$STUB_STATE/zpool-fails" ] && { echo "zpool stub: failing" >&2; exit 1; }
cat "$STUB_STATE/status.json"
STUB

  printf '#!/usr/bin/env bash\necho 0\n' >"$bin/id"

  # is_mounted compares a directory's device with the root's. A file
  # control-unmounted puts the control volume on the root's device.
  cat >"$bin/stat" <<'STUB'
#!/usr/bin/env bash
[ "${*: -1}" = / ] && { echo 1; exit 0; }
[ -e "$STUB_STATE/control-unmounted" ] && echo 1 || echo 2
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

# --- Fixtures ----------------------------------------------------------------

# One pool as `zpool status -j --json-int <pool>` reports it: the vdev tree
# nested under "vdevs", the latest scan under "scan_stats", and the count of
# permanent data errors as "error_count".
#   pool_json <name> <state> <scan function> <scan state> <end> <scan errors>
#             <data errors> <checksum errors on the second disk>
pool_json() {
  local scan=""
  if [ "$3" != - ]; then
    scan=$(printf ',"scan_stats":{"function":"%s","state":"%s","start_time":1699990000,"end_time":%s,"to_examine":1000,"examined":1000,"skipped":0,"processed":0,"errors":%s,"bytes_per_scan":0,"pass_start":1699990000,"scrub_pause":0,"scrub_spent_paused":0,"issued_bytes_per_scan":0,"issued":1000}' \
      "$3" "$4" "$5" "$6")
  fi
  cat <<JSON
"$1": {
  "name": "$1", "type": "POOL", "state": "$2", "guid": 1, "txg": 1,
  "spa_version": 5000, "zpl_version": 5,
  "vdevs": {
    "$1": {
      "name": "$1", "vdev_type": "root", "guid": 2, "state": "$2",
      "read_errors": 0, "write_errors": 0, "checksum_errors": 0,
      "vdevs": {
        "mirror-0": {
          "name": "mirror-0", "vdev_type": "mirror", "guid": 3, "state": "$2",
          "read_errors": 0, "write_errors": 0, "checksum_errors": 0,
          "vdevs": {
            "disk-a": {
              "name": "disk-a", "vdev_type": "disk", "guid": 4, "state": "ONLINE",
              "read_errors": 0, "write_errors": 0, "checksum_errors": 0, "slow_ios": 0
            },
            "disk-b": {
              "name": "disk-b", "vdev_type": "disk", "guid": 5, "state": "ONLINE",
              "read_errors": 1, "write_errors": 2, "checksum_errors": $8, "slow_ios": 0
            }
          }
        }
      }
    }
  },
  "error_count": $7$scan
}
JSON
}

write_status() { # write_status <pool_json output>...
  {
    echo '{"output_version": {"command": "zpool status", "vers_major": 0, "vers_minor": 1}, "pools": {'
    local first=1 pool
    for pool in "$@"; do
      [ "$first" -eq 1 ] || echo ','
      first=0
      printf '%s\n' "$pool"
    done
    echo '}}'
  } >"$STUB_STATE/status.json"
}

# --- Cases -------------------------------------------------------------------

new_case() {
  current="$1"
  CASE="$WORK/case-$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' -)"
  ROOT="$CASE/root"
  STUB_STATE="$CASE/state"
  BIN="$CASE/bin"
  SRC="$CASE/src"
  CHECKOUT="$ROOT/opt/fil-one"
  CONTROL="$ROOT/mnt/data/fil-one/control"
  METRICS="$CONTROL/state/metrics"
  PROM="$METRICS/zfs_pool.prom"
  mkdir -p "$ROOT/etc/fil-one" "$ROOT/run/fil-one" "$CONTROL" "$STUB_STATE" "$BIN" "$SRC" \
    "$CHECKOUT/nodes/$NODE"
  : >"$STUB_STATE/calls"
  write_stubs "$BIN"

  cat >"$CHECKOUT/nodes/$NODE/node.env" <<ENV
FILONE_NODE=$NODE
STAGE=test
REGION_LABEL=test-1
FILONE_CONTROL_DIR=/mnt/data/fil-one/control
ENV
  cat >"$ROOT/etc/fil-one/node.conf" <<CONF
FILONE_NODE=$NODE
FILONE_CHECKOUT=$CHECKOUT
FILONE_GIT_REF=main
CONF

  # The code under test, with its absolute paths moved under the case root.
  # node.env is read from the checkout, so its control path moves too.
  cp -R "$SCRIPTS/report-pool-health.sh" "$SCRIPTS/lib.sh" "$SCRIPTS/lib" "$SRC/"
  local file
  for file in "$SRC/report-pool-health.sh" "$SRC/lib.sh" "$SRC"/lib/*.sh "$CHECKOUT/nodes/$NODE/node.env"; do
    sed -e "s#/etc/fil-one#$ROOT/etc/fil-one#g" \
      -e "s#/run/fil-one#$ROOT/run/fil-one#g" \
      -e "s#/mnt/#$ROOT/mnt/#g" "$file" >"$file.new"
    mv "$file.new" "$file"
  done
}

run_report() {
  status=0
  PATH="$BIN:$PATH" STUB_STATE="$STUB_STATE" \
    bash "$SRC/report-pool-health.sh" "$@" >"$CASE/output" 2>&1 || status=$?
}

succeeded() { [ "$status" -eq 0 ]; }
failed() { [ "$status" -ne 0 ]; }
said() { grep -qF -- "$1" "$CASE/output"; }
has_line() { [ -f "$PROM" ] && grep -qxF -- "$1" "$PROM"; }
lacks_metric() { [ -f "$PROM" ] && ! grep -q "^$1[{ ]" "$PROM"; }
called() { grep -qxF -- "$1" "$STUB_STATE/calls"; }
no_temp_files() { [ -z "$(find "$METRICS" -name '.*' -type f 2>/dev/null)" ]; }
mode_is() { [ -n "$(find "$1" -perm "$2")" ]; }

# Every sample's family has exactly one HELP and one TYPE line, which is what
# the textfile collector needs to parse the file. A family declared twice would
# take every textfile metric on the node down with it.
well_formed() {
  local family
  [ -f "$PROM" ] || return 1
  while read -r family; do
    [ "$(grep -c "^# HELP $family " "$PROM")" -eq 1 ] || return 1
    [ "$(grep -c "^# TYPE $family gauge$" "$PROM")" -eq 1 ] || return 1
  done < <(grep -v "^#" "$PROM" | sed -e "s/[{ ].*//" | sort -u)
  awk '!/^#/ && !/^[a-z_]+\{[^}]*\} [0-9]+$/ { bad = 1 } END { exit bad }' "$PROM"
}

show_output_on_failure() {
  local before="$1"
  [ "$failures" -eq "$before" ] && return 0
  sed 's/^/       | /' "$CASE/output"
  [ ! -f "$PROM" ] || sed 's/^/       > /' "$PROM"
}

before=$failures
new_case "healthy mirror, last scrub clean"
write_status "$(pool_json data ONLINE SCRUB FINISHED 1700000000 0 0 0)"
run_report
check "succeeds" succeeded
check "asks zpool for every pool as JSON with integers" called "zpool status -j --json-int"
check "writes zfs_pool.prom readable by Alloy" mode_is "$PROM" 644
check "the file parses as one family per name" well_formed
check "reports the scrub's errors" has_line 'zfs_pool_scan_errors{zpool="data",function="scrub"} 0'
check "reports when the scrub ended" has_line 'zfs_pool_scan_end_timestamp{zpool="data",function="scrub"} 1700000000'
check "reports the pool's data errors" has_line 'zfs_pool_data_errors{zpool="data"} 0'
check "reports the root vdev" has_line 'zfs_pool_vdev_errors{zpool="data",vdev="data",type="checksum"} 0'
check "reports the mirror" has_line 'zfs_pool_vdev_errors{zpool="data",vdev="mirror-0",type="read"} 0'
check "reports each disk's read errors" has_line 'zfs_pool_vdev_errors{zpool="data",vdev="disk-b",type="read"} 1'
check "reports each disk's write errors" has_line 'zfs_pool_vdev_errors{zpool="data",vdev="disk-b",type="write"} 2'
check "reports each disk's checksum errors" has_line 'zfs_pool_vdev_errors{zpool="data",vdev="disk-b",type="checksum"} 0'
check "leaves no temporary file behind" no_temp_files
check "leaves the pool state to the zfs collector" lacks_metric zfs_pool_state
show_output_on_failure "$before"

before=$failures
new_case "scrub found errors"
write_status "$(pool_json data ONLINE SCRUB FINISHED 1700000000 3 2 7)"
run_report
check "succeeds" succeeded
check "reports the scrub's errors" has_line 'zfs_pool_scan_errors{zpool="data",function="scrub"} 3'
check "reports the permanent data errors" has_line 'zfs_pool_data_errors{zpool="data"} 2'
check "reports the disk's checksum errors" has_line 'zfs_pool_vdev_errors{zpool="data",vdev="disk-b",type="checksum"} 7'
show_output_on_failure "$before"

before=$failures
new_case "resilver in progress"
write_status "$(pool_json data DEGRADED RESILVER SCANNING 0 0 0 0)"
run_report
check "succeeds" succeeded
check "labels the scan a resilver" has_line 'zfs_pool_scan_errors{zpool="data",function="resilver"} 0'
check "reports no end time while it runs" has_line 'zfs_pool_scan_end_timestamp{zpool="data",function="resilver"} 0'
check "reports no scrub" lacks_metric 'zfs_pool_scan_errors{zpool="data",function="scrub"}'
show_output_on_failure "$before"

before=$failures
new_case "never scanned"
write_status "$(pool_json data ONLINE NONE NONE 0 0 0 0)"
run_report
check "succeeds" succeeded
check "reports no scan" lacks_metric zfs_pool_scan_errors
check "reports no scan end" lacks_metric zfs_pool_scan_end_timestamp
check "still reports the data errors" has_line 'zfs_pool_data_errors{zpool="data"} 0'
check "the file parses as one family per name" well_formed
show_output_on_failure "$before"

before=$failures
new_case "no scan stats at all"
write_status "$(pool_json data ONLINE - - - - 0 0)"
run_report
check "succeeds" succeeded
check "reports no scan" lacks_metric zfs_pool_scan_errors
check "the file parses as one family per name" well_formed
show_output_on_failure "$before"

before=$failures
new_case "two pools"
write_status "$(pool_json data ONLINE SCRUB FINISHED 1700000000 0 0 0)" \
  "$(pool_json spare ONLINE SCRUB FINISHED 1700000500 1 0 0)"
run_report
check "succeeds" succeeded
check "reports the first pool" has_line 'zfs_pool_scan_errors{zpool="data",function="scrub"} 0'
check "reports the second pool" has_line 'zfs_pool_scan_errors{zpool="spare",function="scrub"} 1'
check "keeps each pool's vdevs apart" has_line 'zfs_pool_vdev_errors{zpool="spare",vdev="disk-b",type="read"} 1'
check "the file parses as one family per name" well_formed
show_output_on_failure "$before"

before=$failures
new_case "zpool fails"
write_status "$(pool_json data ONLINE SCRUB FINISHED 1700000000 0 0 0)"
run_report
cp "$PROM" "$CASE/previous.prom" 2>/dev/null || echo "no first report" >"$CASE/previous.prom"
touch "$STUB_STATE/zpool-fails"
run_report
check "exits non-zero" failed
check "says zpool status failed" said "zpool status"
check "leaves the last report in place" cmp -s "$PROM" "$CASE/previous.prom"
check "leaves no temporary file behind" no_temp_files
show_output_on_failure "$before"

before=$failures
new_case "zpool prints something other than JSON"
write_status "$(pool_json data ONLINE SCRUB FINISHED 1700000000 0 0 0)"
run_report
cp "$PROM" "$CASE/previous.prom" 2>/dev/null || echo "no first report" >"$CASE/previous.prom"
echo "no pools available" >"$STUB_STATE/status.json"
run_report
check "exits non-zero" failed
check "leaves the last report in place" cmp -s "$PROM" "$CASE/previous.prom"
check "leaves no temporary file behind" no_temp_files
show_output_on_failure "$before"

before=$failures
new_case "control volume not mounted"
write_status "$(pool_json data ONLINE SCRUB FINISHED 1700000000 0 0 0)"
touch "$STUB_STATE/control-unmounted"
run_report
check "exits non-zero" failed
check "says the control volume is not mounted" said "control volume is not mounted"
check "writes nothing" test ! -e "$PROM"
show_output_on_failure "$before"

before=$failures
new_case "help and unknown options"
run_report --help
check "help succeeds" succeeded
check "help prints the header" said "Usage:"
run_report --bogus
check "an unknown option fails" failed
check "and names it" said "unknown option: --bogus"
show_output_on_failure "$before"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
