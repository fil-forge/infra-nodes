#!/usr/bin/env bash
# Tests for scripts/host/bootstrap-prod-us-east-2.sh, run from any machine:
#
#   scripts/host/tests/bootstrap-prod-us-east-2.test.sh
#
# The script runs as root against a real pool, so here it runs against stubs.
# Each case puts stub zfs, zpool, docker, ufw, systemctl and id commands first
# on PATH. They answer from files in a temporary directory and append every
# call to a log the assertions read. Stub install and cmp commands absorb the
# writes: a path under /etc, /run, /mnt, /var/lib or /root is moved under the
# case's own root directory, so nothing outside the temporary directory changes.
#
# Plain bash with no dependencies beyond the ones the script itself has, and
# written for the bash 3.2 macOS ships as well as for a current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bootstrap-prod-us-east-2.sh"
REAL_CMP="$(command -v cmp)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-prod-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 7 TB, a round number so the expected values below can be checked by hand.
POOL_SIZE=7000000000000
MIB=1048576
GIB=1073741824
JUMP=192.0.2.10 # a documentation address (RFC 5737), never a real one

# The values bootstrap must compute from POOL_SIZE: a percentage of the pool,
# rounded down to a whole MiB, or a fixed size.
EXPECT_POSTGRES_RESERVATION=$((POOL_SIZE * 20 / 100 / MIB * MIB))
EXPECT_OPENBAO_RESERVATION=$((10 * GIB))
EXPECT_STATE_QUOTA=$((50 * GIB))
EXPECT_PIRI_QUOTA=$((50 * GIB))
EXPECT_SEGMENTS_QUOTA=$((POOL_SIZE * 5 / 100 / MIB * MIB))
EXPECT_BLOBS_QUOTA=$((POOL_SIZE * 50 / 100 / MIB * MIB))
EXPECT_BLOB_BUDGET=$((EXPECT_BLOBS_QUOTA * 80 / 100))

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

  cat >"$bin/id" <<'STUB'
#!/usr/bin/env bash
echo "id $*" >>"$STUB_STATE/calls"
[ "$1" = -u ] && { cat "$STUB_STATE/uid"; exit 0; }
exit 1
STUB

  # Datasets are directories under $STUB_STATE/zfs, named with % for /, and
  # each property is a file in its directory. An unset quota or reservation
  # reads 0, which is what `zfs get -p` prints for none.
  cat >"$bin/zfs" <<'STUB'
#!/usr/bin/env bash
echo "zfs $*" >>"$STUB_STATE/calls"
root="$STUB_STATE/zfs"
key() { printf '%s' "$1" | tr / %; }
ds="${!#}"
case "$1" in
  list)
    [ -d "$root/$(key "$ds")" ] || { echo "cannot open '$ds': dataset does not exist" >&2; exit 1; }
    echo "$ds" ;;
  get)
    prop="${@: -2:1}"
    [ -d "$root/$(key "$ds")" ] || { echo "cannot open '$ds': dataset does not exist" >&2; exit 1; }
    if [ -f "$root/$(key "$ds")/$prop" ]; then
      cat "$root/$(key "$ds")/$prop"
    else
      case "$prop" in quota|reservation) echo 0 ;; *) echo - ;; esac
    fi ;;
  create)
    shift
    props=""
    while [ $# -gt 1 ]; do
      case "$1" in
        -o) props="$props $2"; shift 2 ;;
        -p) shift ;;
        *) echo "stub zfs: unexpected create argument $1" >&2; exit 2 ;;
      esac
    done
    [ -d "$root/$(key "$ds")" ] && { echo "cannot create '$ds': dataset already exists" >&2; exit 1; }
    path="$ds"
    while [ "$path" != "${path%/*}" ]; do
      mkdir -p "$root/$(key "$path")"
      echo yes >"$root/$(key "$path")/mounted"
      path="${path%/*}"
    done
    for pair in $props; do
      printf '%s\n' "${pair#*=}" >"$root/$(key "$ds")/${pair%%=*}"
    done ;;
  *)
    exit 0 ;;
esac
STUB

  cat >"$bin/zpool" <<'STUB'
#!/usr/bin/env bash
echo "zpool $*" >>"$STUB_STATE/calls"
[ -f "$STUB_STATE/zpool-imported" ] || { echo "cannot open 'data': no such pool" >&2; exit 1; }
case "$1" in
  list) echo data ;;
  get) cat "$STUB_STATE/zpool-${@: -2:1}" ;;
  status) cat "$STUB_STATE/zpool-status" ;;
  *) exit 0 ;;
esac
STUB

  cat >"$bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_STATE/calls"
case "$1 ${2:-}" in
  "compose version") cat "$STUB_STATE/compose-version" ;;
  "network inspect")
    [ -f "$STUB_STATE/network-subnet" ] || { echo "network filone not found" >&2; exit 1; }
    if [ "$3" = -f ]; then cat "$STUB_STATE/network-subnet"; else echo '[]'; fi ;;
  "network create")
    printf '%s\n' "$4" >"$STUB_STATE/network-subnet" ;;
  "ps -q") cat "$STUB_STATE/containers" ;;
  *) exit 0 ;;
esac
STUB

  cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_STATE/calls"
case "$1" in
  is-enabled)
    state="$(cat "$STUB_STATE/enabled-$2" 2>/dev/null || echo disabled)"
    echo "$state"
    [ "$state" = enabled ] ;;
  show) cat "$STUB_STATE/docker-dropins" ;;
  *) exit 0 ;;
esac
STUB

  cat >"$bin/ufw" <<'STUB'
#!/usr/bin/env bash
echo "ufw $*" >>"$STUB_STATE/calls"
[ "$*" = status ] && cat "$STUB_STATE/ufw-status"
exit 0
STUB

  # Writes land under $STUB_ROOT instead of on this machine.
  cat >"$bin/install" <<'STUB'
#!/usr/bin/env bash
echo "install $*" >>"$STUB_STATE/calls"
map() {
  case "$1" in
    /etc/*|/run/*|/mnt/*|/var/lib/*|/root/*) printf '%s%s' "$STUB_ROOT" "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
dirs=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -d) dirs=1 ;;
    -m|-o|-g) shift ;;
    *) args+=("$(map "$1")") ;;
  esac
  shift
done
if [ "$dirs" = 1 ]; then mkdir -p "${args[@]}"; exit; fi
n=${#args[@]}
dest="${args[$((n - 1))]}"
if [ "$n" -gt 2 ] || [ -d "$dest" ]; then
  mkdir -p "$dest"
  cp "${args[@]:0:$((n - 1))}" "$dest/"
else
  mkdir -p "$(dirname "$dest")"
  cp "${args[0]}" "$dest"
fi
STUB

  cat >"$bin/cmp" <<'STUB'
#!/usr/bin/env bash
map() {
  case "$1" in
    /etc/*|/run/*|/mnt/*|/var/lib/*|/root/*) printf '%s%s' "$STUB_ROOT" "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
args=()
for arg in "$@"; do args+=("$(map "$arg")"); done
exec "$REAL_CMP" "${args[@]}"
STUB

  chmod +x "$bin"/*
}

# --- A healthy host ----------------------------------------------------------

zfs_set() { # zfs_set <dataset> <property> <value>
  local dir
  dir="$STATE/zfs/$(printf '%s' "$1" | tr / %)"
  mkdir -p "$dir"
  printf '%s\n' "$3" >"$dir/$2"
}

# A new case: fresh state, a host that passes every check, and no calls yet.
new_case() {
  current="$1"
  CASE="$WORK/case-$((++case_count))"
  STATE="$CASE/state"
  ROOT="$CASE/root"
  mkdir -p "$CASE/bin" "$STATE/zfs" "$ROOT" "$CASE/tmp"
  write_stubs "$CASE/bin"
  : >"$STATE/calls"

  echo 0 >"$STATE/uid"
  echo 2.40.3 >"$STATE/compose-version"
  : >"$STATE/containers"

  touch "$STATE/zpool-imported"
  echo ONLINE >"$STATE/zpool-health"
  echo "$POOL_SIZE" >"$STATE/zpool-size"
  write_pool_status ONLINE nvme-FIRST_DRIVE nvme-SECOND_DRIVE

  zfs_set data mountpoint /mnt/data
  zfs_set data mounted yes
  zfs_set data encryption aes-256-gcm
  zfs_set data keystatus available
  zfs_set data keylocation file:///etc/zfs/keys/data.key

  echo enabled >"$STATE/enabled-zfs-load-key-data.service"
  echo /etc/systemd/system/docker.service.d/10-zfs-mounted.conf >"$STATE/docker-dropins"

  write_ufw_status "$JUMP"
}
case_count=0

# zpool status for pool data with one mirror of the given members.
write_pool_status() { # write_pool_status <state> <member>...
  local state="$1" member
  shift
  {
    printf '  pool: data\n state: %s\nconfig:\n\n' "$state"
    printf '\tNAME                    STATE     READ WRITE CKSUM\n'
    printf '\tdata                    %s       0     0     0\n' "$state"
    printf '\t  mirror-0              %s       0     0     0\n' "$state"
    for member in "$@"; do
      printf '\t    %-20s  ONLINE       0     0     0\n' "$member"
    done
    printf '\nerrors: No known data errors\n'
  } >"$STATE/zpool-status"
}

write_ufw_status() { # write_ufw_status <address admitted to port 22>
  {
    printf 'Status: active\n\n'
    printf 'To                         Action      From\n'
    printf -- '--                         ------      ----\n'
    printf '22/tcp                     ALLOW       %s                # jump host\n' "$1"
    printf '80/tcp                     ALLOW       Anywhere\n'
  } >"$STATE/ufw-status"
}

run_bootstrap() {
  # The address the script reads, or -u to run it with none.
  local jump=("JUMP_HOST_ADDRESS=$JUMP")
  [ -z "${JUMP_HOST_ADDRESS_UNSET:-}" ] || jump=(-u JUMP_HOST_ADDRESS)
  set +e
  env "${jump[@]}" PATH="$CASE/bin:$PATH" \
    STUB_STATE="$STATE" STUB_ROOT="$ROOT" REAL_CMP="$REAL_CMP" TMPDIR="$CASE/tmp" \
    bash "$SCRIPT" >"$CASE/stdout" 2>"$CASE/stderr"
  status=$?
  set -e
}

# --- Assertions --------------------------------------------------------------

called() { grep -qE "$1" "$STATE/calls"; }
not_called() { ! called "$1"; }
failed() { [ "$status" -ne 0 ]; }
succeeded() {
  [ "$status" -eq 0 ] || { sed 's/^/       /' "$CASE/stderr"; return 1; }
}
said() { grep -qF -- "$1" "$CASE/stderr"; }
printed() { grep -qF -- "$1" "$CASE/stdout"; }
prop_is() { # prop_is <dataset> <property> <value>
  [ "$(cat "$STATE/zfs/$(printf '%s' "$1" | tr / %)/$2" 2>/dev/null)" = "$3" ]
}
root_empty() { [ -z "$(ls -A "$ROOT")" ]; }

# Every file under the case's root with its checksum, less the completion
# stamp, which records the time of the last run that finished.
root_files() { (cd "$ROOT" && find . -type f ! -name bootstrap-complete -exec cksum {} + | sort); }

# File installs other than the completion stamp.
no_file_installs() { ! grep -E '^install -m' "$STATE/calls" | grep -qv bootstrap-complete; }

# Anything that would change the host. Only calls the stubs saw count, so a
# write the stubs did not absorb would show up in root_empty instead.
CHANGES='^(zfs (create|set|destroy|inherit)|docker network (create|rm)|systemctl (restart|start|stop|enable|disable|daemon-reload)|install )'
changed_nothing() { not_called "$CHANGES" && root_empty; }

# The script must never change a firewall rule: only `ufw status` is allowed.
only_ufw_status() { ! grep -E '^ufw ' "$STATE/calls" | grep -qvx 'ufw status'; }

# A verify failure: dies, names its check, and changes nothing.
expect_check_failure() { # expect_check_failure <check name>
  run_bootstrap
  check "exits non-zero" failed
  check "names the check '$1'" said "check '$1' failed"
  check "changes nothing" changed_nothing
  check "calls ufw only to read its status" only_ufw_status
}

# --- Cases -------------------------------------------------------------------

echo "bootstrap-prod-us-east-2.sh"

new_case "not root"
echo 1000 >"$STATE/uid"
expect_check_failure root

new_case "old Compose"
echo 2.39.1 >"$STATE/compose-version"
expect_check_failure "compose version"

new_case "pool not imported"
rm "$STATE/zpool-imported"
expect_check_failure "pool imported"

new_case "pool at another mount point"
zfs_set data mountpoint /data
expect_check_failure "pool mountpoint"

new_case "pool not mounted"
zfs_set data mounted no
expect_check_failure "pool mounted"

new_case "pool degraded"
echo DEGRADED >"$STATE/zpool-health"
expect_check_failure "pool health"

new_case "one mirror member"
write_pool_status ONLINE nvme-FIRST_DRIVE
expect_check_failure "pool mirror"

new_case "member named by kernel name"
write_pool_status ONLINE nvme0n1 nvme-SECOND_DRIVE
expect_check_failure "pool mirror"

new_case "pool unencrypted"
zfs_set data encryption off
expect_check_failure "pool encryption"

new_case "key not loaded"
zfs_set data keystatus unavailable
expect_check_failure "pool key status"

new_case "key not read from the key file"
zfs_set data keylocation prompt
expect_check_failure "pool key location"

new_case "key unit not enabled"
echo disabled >"$STATE/enabled-zfs-load-key-data.service"
expect_check_failure "key unit"

new_case "Docker drop-in missing"
: >"$STATE/docker-dropins"
expect_check_failure "docker drop-in"

new_case "jump host address unset"
JUMP_HOST_ADDRESS_UNSET=1 expect_check_failure "jump host address"

new_case "no SSH rule for the jump host"
write_ufw_status 198.51.100.7
expect_check_failure "ssh rule"

new_case "UFW inactive"
printf 'Status: inactive\n' >"$STATE/ufw-status"
expect_check_failure "ufw active"

new_case "clean first run"
run_bootstrap
check "succeeds" succeeded
check "creates control/postgres with its reservation" \
  prop_is data/fil-one/control/postgres reservation "$EXPECT_POSTGRES_RESERVATION"
check "creates control/openbao with its reservation" \
  prop_is data/fil-one/control/openbao reservation "$EXPECT_OPENBAO_RESERVATION"
check "creates control/state with its quota" \
  prop_is data/fil-one/control/state quota "$EXPECT_STATE_QUOTA"
check "creates piri with its quota" \
  prop_is data/fil-one/piri quota "$EXPECT_PIRI_QUOTA"
check "creates ingot/segments with its quota" \
  prop_is data/fil-one/ingot/segments quota "$EXPECT_SEGMENTS_QUOTA"
check "creates ingot/blobs with its quota" \
  prop_is data/fil-one/ingot/blobs quota "$EXPECT_BLOBS_QUOTA"
check "creates exactly six datasets" \
  test "$(grep -c '^zfs create' "$STATE/calls")" -eq 6
check "writes daemon.json with json-file rotation" \
  grep -q '"log-driver": "json-file"' "$ROOT/etc/docker/daemon.json"
check "restarts Docker for the new daemon.json" called '^systemctl restart docker'
check "creates the filone network" called '^docker network create --subnet 172\.18\.0\.0/16 filone'
check "writes node.conf for prod/us-east-2" grep -qx 'FILONE_NODE=prod/us-east-2' "$ROOT/etc/fil-one/node.conf"
check "node.conf tracks main" grep -qx 'FILONE_GIT_REF=main' "$ROOT/etc/fil-one/node.conf"
check "node.conf names the checkout" grep -q '^FILONE_CHECKOUT=/' "$ROOT/etc/fil-one/node.conf"
check "writes the tmpfiles.d entries" grep -qx 'd /run/fil-one/secrets 0700 root root -' "$ROOT/etc/tmpfiles.d/filone.conf"
check "creates the secrets tmpfs directory" test -d "$ROOT/run/fil-one/secrets"
check "installs the systemd units" test -f "$ROOT/etc/systemd/system/filone-reconcile.timer"
check "does not enable any unit" not_called '^systemctl enable'
check "prints the Ingot blob budget" printed "INGOT_LOCAL_BLOB_MAX_BYTES=$EXPECT_BLOB_BUDGET"
check "calls ufw only to read its status" only_ufw_status

current="second run"
: >"$STATE/calls"
before="$(root_files)"
run_bootstrap
check "succeeds" succeeded
check "creates and sets no dataset" not_called '^zfs (create|set)'
check "leaves the network alone" not_called '^docker network create'
check "does not restart Docker" not_called '^systemctl restart'
check "does not reload systemd" not_called '^systemctl daemon-reload'
check "writes no file other than the completion stamp" no_file_installs
check "leaves the same files behind" test "$(root_files)" = "$before"
check "still prints the Ingot blob budget" printed "INGOT_LOCAL_BLOB_MAX_BYTES=$EXPECT_BLOB_BUDGET"
check "calls ufw only to read its status" only_ufw_status

current="daemon.json matches while containers run"
: >"$STATE/calls"
echo 0123456789ab >"$STATE/containers"
run_bootstrap
check "succeeds" succeeded
check "does not restart Docker" not_called '^systemctl restart'
check "does not rewrite daemon.json" not_called '^install .*/etc/docker/daemon\.json'

new_case "daemon.json differs while containers run"
mkdir -p "$ROOT/etc/docker"
printf '{"log-driver": "local"}\n' >"$ROOT/etc/docker/daemon.json"
echo 0123456789ab >"$STATE/containers"
run_bootstrap
check "exits non-zero" failed
check "names the check 'docker log config'" said "check 'docker log config' failed"
check "leaves daemon.json as it was" grep -qx '{"log-driver": "local"}' "$ROOT/etc/docker/daemon.json"
check "changes nothing else" not_called "$CHANGES"
check "calls ufw only to read its status" only_ufw_status

new_case "datasets with other values"
zfs_set data/fil-one/ingot/blobs quota 1000000
zfs_set data/fil-one/control/postgres reservation 2000000
run_bootstrap
check "exits non-zero" failed
check "reports the blobs quota" said "data/fil-one/ingot/blobs: quota is 1000000, expected $EXPECT_BLOBS_QUOTA"
check "reports the postgres reservation as well" \
  said "data/fil-one/control/postgres: reservation is 2000000, expected $EXPECT_POSTGRES_RESERVATION"
check "leaves the blobs quota alone" prop_is data/fil-one/ingot/blobs quota 1000000
check "leaves the postgres reservation alone" prop_is data/fil-one/control/postgres reservation 2000000
check "sets no property" not_called '^zfs set'
check "does not go on to daemon.json" test ! -e "$ROOT/etc/docker/daemon.json"
check "calls ufw only to read its status" only_ufw_status

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
