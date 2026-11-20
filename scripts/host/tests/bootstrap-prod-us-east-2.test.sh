#!/usr/bin/env bash
# Tests for scripts/host/bootstrap-prod-us-east-2.sh, run from any machine:
#
#   scripts/host/tests/bootstrap-prod-us-east-2.test.sh
#
# The script runs as root against a real pool, so here it runs against stubs.
# Each case puts stub zfs, zpool, docker, ufw, systemctl, git and id commands first
# on PATH. They answer from files in a temporary directory and append every
# call to a log the assertions read. Stub install, cmp, diff and rm commands
# absorb the file reads and writes: a path under /etc, /run, /mnt, /var/lib or
# /root is moved under the case's own root directory. The script reads and
# writes those paths only through these commands, so nothing outside the
# temporary directory changes, even on a host with FilOne installed.
#
# Plain bash with no dependencies beyond the ones the script itself has, and
# written for the bash 3.2 macOS ships as well as for a current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bootstrap-prod-us-east-2.sh"
REAL_CMP="$(command -v cmp)"
REAL_DIFF="$(command -v diff)"
REAL_RM="$(command -v rm)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-prod-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 7 TB, a round number so the expected values below can be checked by hand.
POOL_SIZE=7000000000000
MIB=1048576
GIB=1073741824
# Documentation addresses (RFC 5737), never real ones.
JUMP=192.0.2.10
OTHER=198.51.100.7

# The values bootstrap must compute from POOL_SIZE: a percentage of the pool,
# rounded down to a whole MiB, or a fixed size.
EXPECT_POSTGRES_RESERVATION=$((POOL_SIZE * 20 / 100 / MIB * MIB))
EXPECT_OPENBAO_RESERVATION=$((10 * GIB))
EXPECT_STATE_QUOTA=$((50 * GIB))
EXPECT_CADDY_QUOTA=$((1 * GIB))
EXPECT_ALLOY_QUOTA=$((10 * GIB))
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
  local bin="$1" tool

  cat >"$bin/id" <<'STUB'
#!/usr/bin/env bash
echo "id $*" >>"$STUB_STATE/calls"
[ "$1" = -u ] && { cat "$STUB_STATE/uid"; exit 0; }
exit 1
STUB

  # Where git says the checkout the script runs from is. No file means the
  # script is not in a checkout.
  cat >"$bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >>"$STUB_STATE/calls"
[ "$*" = "-C $STUB_RUNNING_FROM rev-parse --show-toplevel" ] || exit 1
cat "$STUB_STATE/checkout" 2>/dev/null
STUB

  # Datasets are directories under $STUB_STATE/zfs, named with % for /, and
  # each property is a file in its directory. An unset quota or reservation
  # reads 0, which is what `zfs get -p` prints for none, and an unset
  # mountpoint is inherited from the nearest ancestor that sets one. An unset
  # encryptionroot reads data, as for a dataset that inherits the pool's key,
  # and an unset canmount reads on, its default.
  # A file get-fails-<property> makes reading that property fail.
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
    [ ! -f "$STUB_STATE/get-fails-$prop" ] || { echo "stub zfs: get $prop failed" >&2; exit 1; }
    [ -d "$root/$(key "$ds")" ] || { echo "cannot open '$ds': dataset does not exist" >&2; exit 1; }
    if [ -f "$root/$(key "$ds")/$prop" ]; then
      cat "$root/$(key "$ds")/$prop"
    elif [ "$prop" = mountpoint ]; then
      d="$ds" rest=""
      while [ ! -f "$root/$(key "$d")/mountpoint" ]; do
        [ "$d" != "${d%/*}" ] || { echo -; exit 0; }
        rest="/${d##*/}$rest"
        d="${d%/*}"
      done
      echo "$(cat "$root/$(key "$d")/mountpoint")$rest"
    else
      case "$prop" in quota|reservation) echo 0 ;; encryptionroot) echo data ;; canmount) echo on ;; *) echo - ;; esac
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
    mounted=yes
    [ ! -f "$STUB_STATE/create-unmounted" ] || mounted=no
    path="$ds"
    while [ "$path" != "${path%/*}" ]; do
      if [ ! -d "$root/$(key "$path")" ]; then
        mkdir -p "$root/$(key "$path")"
        echo "$mounted" >"$root/$(key "$path")/mounted"
      fi
      path="${path%/*}"
    done
    for pair in $props; do
      printf '%s\n' "${pair#*=}" >"$root/$(key "$ds")/${pair%%=*}"
    done ;;
  load-key)
    [ "$2" = -n ] || { echo "stub zfs: load-key without -n" >&2; exit 2; }
    [ ! -f "$STUB_STATE/load-key-fails" ] || { echo "Key load error: Failed to open key material file." >&2; exit 255; }
    exit 0 ;;
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
  get)
    prop="${@: -2:1}"
    [ ! -f "$STUB_STATE/zpool-get-fails-$prop" ] || { echo "stub zpool: get $prop failed" >&2; exit 1; }
    cat "$STUB_STATE/zpool-$prop" ;;
  status)
    [ ! -f "$STUB_STATE/zpool-status-fails" ] || { echo "stub zpool: status failed" >&2; exit 1; }
    cat "$STUB_STATE/zpool-status" ;;
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
  "info ")
    [ ! -f "$STUB_STATE/daemon-down" ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; } ;;
  "ps -q")
    [ ! -f "$STUB_STATE/ps-fails" ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
    cat "$STUB_STATE/containers" ;;
  "ps -aq")
    [ ! -f "$STUB_STATE/ps-fails" ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
    cat "$STUB_STATE/containers"
    [ ! -f "$STUB_STATE/stopped-containers" ] || cat "$STUB_STATE/stopped-containers" ;;
  *) exit 0 ;;
esac
STUB

  cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_STATE/calls"
case "$1" in
  # is-enabled exits 0 for static, indirect and the other states systemctl
  # documents with 0, not only for enabled.
  is-enabled)
    state="$(cat "$STUB_STATE/enabled-$2" 2>/dev/null || echo disabled)"
    echo "$state"
    case "$state" in enabled|enabled-runtime|static|indirect|alias|generated|transient) ;; *) exit 1 ;; esac ;;
  show)
    case "$*" in
      *DropInPaths*) cat "$STUB_STATE/docker-dropins" ;;
      *ExecStartPre*) cat "$STUB_STATE/docker-execstartpre" ;;
      *ExecStart*) cat "$STUB_STATE/key-execstart" ;;
      *) exit 1 ;;
    esac ;;
  restart) [ ! -f "$STUB_STATE/restart-fails" ] ;;
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

  # cmp, diff and rm run the real command on the moved paths. rm is logged,
  # so a removal under /etc counts as a change.
  for tool in cmp diff rm; do
    cat >"$bin/$tool" <<STUB
#!/usr/bin/env bash
[ "$tool" != rm ] || echo "rm \$*" >>"\$STUB_STATE/calls"
map() {
  case "\$1" in
    /etc/*|/run/*|/mnt/*|/var/lib/*|/root/*) printf '%s%s' "\$STUB_ROOT" "\$1" ;;
    *) printf '%s' "\$1" ;;
  esac
}
args=()
for arg in "\$@"; do args+=("\$(map "\$arg")"); done
exec "\$REAL_$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')" "\${args[@]}"
STUB
  done

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
  case_count=$((case_count + 1))
  CASE="$WORK/case-$case_count"
  STATE="$CASE/state"
  ROOT="$CASE/root"
  mkdir -p "$CASE/bin" "$STATE/zfs" "$ROOT" "$CASE/tmp"
  write_stubs "$CASE/bin"
  : >"$STATE/calls"

  echo 0 >"$STATE/uid"
  echo /opt/fil-one/infra-nodes >"$STATE/checkout"
  echo 2.40.3 >"$STATE/compose-version"
  : >"$STATE/containers"

  touch "$STATE/zpool-imported"
  echo ONLINE >"$STATE/zpool-health"
  echo "$POOL_SIZE" >"$STATE/zpool-size"
  echo 12 >"$STATE/zpool-ashift"
  echo on >"$STATE/zpool-autotrim"
  write_pool_status nvme-FIRST_DRIVE nvme-SECOND_DRIVE

  zfs_set data mountpoint /mnt/data
  zfs_set data mounted yes
  zfs_set data encryption aes-256-gcm
  zfs_set data keystatus available
  zfs_set data keylocation file:///etc/zfs/keys/data.key
  zfs_set data compression lz4
  zfs_set data atime off
  zfs_set data xattr sa
  zfs_set data acltype posix

  echo enabled >"$STATE/enabled-zfs-load-key-data.service"
  write_key_unit
  echo /etc/systemd/system/docker.service.d/10-zfs-mounted.conf >"$STATE/docker-dropins"
  write_docker_dropin
  # As systemctl show prints a command: its argv joined by spaces.
  printf '%s\n' "{ path=/bin/sh ; argv[]=/bin/sh -c $GUARD ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }" \
    >"$STATE/docker-execstartpre"
  printf '%s\n' "{ path=/bin/sh ; argv[]=/bin/sh -c $LOAD_KEY ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }" \
    >"$STATE/key-execstart"

  write_ufw_status "22/tcp                     ALLOW       $JUMP"
  ROOT_BEFORE="$(root_tree)"
}

# The key unit as the storage record gives it, or with the given contents
# instead.
write_key_unit() { # write_key_unit [contents]
  local dir="$ROOT/etc/systemd/system"
  mkdir -p "$dir"
  if [ $# -gt 0 ]; then
    printf '%s' "$1" >"$dir/zfs-load-key-data.service"
    return
  fi
  cat >"$dir/zfs-load-key-data.service" <<'INI'
[Unit]
Description=Load the ZFS encryption key for the data pool
DefaultDependencies=no
After=zfs-import.target
Before=zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'zfs get -H -o value keystatus data | grep -qx available || zfs load-key data'

[Install]
WantedBy=zfs-mount.service
INI
}

# The command the key unit runs to load the pool's key.
LOAD_KEY='zfs get -H -o value keystatus data | grep -qx available || zfs load-key data'

# The mount guard the drop-in runs before Docker starts.
GUARD='zfs list -H -o name data >/dev/null && ! zfs get -H -r -t filesystem -o value mounted data | grep -vqx yes'

# The Docker drop-in as the storage record gives it, or with the given
# contents instead.
write_docker_dropin() { # write_docker_dropin [contents]
  local dir="$ROOT/etc/systemd/system/docker.service.d"
  mkdir -p "$dir"
  if [ $# -gt 0 ]; then
    printf '%s' "$1" >"$dir/10-zfs-mounted.conf"
    return
  fi
  cat >"$dir/10-zfs-mounted.conf" <<'INI'
[Unit]
Wants=zfs-mount.service
After=zfs-mount.service

[Service]
ExecStartPre=/bin/sh -c 'zfs list -H -o name data >/dev/null && ! zfs get -H -r -t filesystem -o value mounted data | grep -vqx yes'
INI
}
case_count=0

# zpool status for pool data with one mirror of the given members. A member
# is a name, name:STATE for one that is not ONLINE, or name:STATE:CKSUM for one
# that counts checksum errors. $POOL_DATA_ERRORS, when set, replaces the final
# "No known data errors". $POOL_EXTRA, when set,
# is appended after the pool's own tree, as a logs or cache section would be.
# The status and scan lines carry tab-indented continuations, as real output
# does, which the script must not take for the config.
write_pool_status() { # write_pool_status <member>...
  local member name state cksum
  {
    printf '  pool: data\n state: ONLINE\n'
    printf 'status: Some supported and requested features are not enabled on the pool.\n'
    printf '\tThe pool can still be used, but some features are unavailable.\n'
    printf '  scan: scrub repaired 0B in 00:00:01 with 0 errors on Sun Nov  8 00:24:02 2026\n'
    printf 'config:\n\n'
    printf '\tNAME                    STATE     READ WRITE CKSUM\n'
    printf '\tdata                    ONLINE       %s\n' "${POOL_ROW_COUNTS:-0     0     0}"
    printf '\t  mirror-0              ONLINE       %s\n' "${VDEV_ROW_COUNTS:-0     0     0}"
    for member in "$@"; do
      name="${member%%:*}"
      state=ONLINE
      cksum=0
      [ "$name" = "$member" ] || state="${member#*:}"
      case "$state" in *:*) cksum="${state#*:}" state="${state%%:*}" ;; esac
      printf '\t    %-20s  %s       0     0     %s\n' "$name" "$state" "$cksum"
    done
    [ -z "${POOL_EXTRA:-}" ] || printf '%b' "$POOL_EXTRA"
    printf '\nerrors: %s\n' "${POOL_DATA_ERRORS:-No known data errors}"
  } >"$STATE/zpool-status"
}

write_ufw_status() { # write_ufw_status <rule line>...
  local line
  {
    printf 'Status: active\n\n'
    printf 'To                         Action      From\n'
    printf -- '--                         ------      ----\n'
    for line in "$@"; do printf '%s\n' "$line"; done
    printf '80/tcp                     ALLOW       Anywhere\n'
  } >"$STATE/ufw-status"
}

run_bootstrap() {
  # The address the script reads, or -u to run it with none.
  local jump=("JUMP_HOST_ADDRESS=${JUMP_ADDRESS:-$JUMP}")
  [ -z "${JUMP_HOST_ADDRESS_UNSET:-}" ] || jump=(-u JUMP_HOST_ADDRESS)
  set +e
  env "${jump[@]}" PATH="$CASE/bin:$PATH" \
    STUB_STATE="$STATE" STUB_ROOT="$ROOT" TMPDIR="$CASE/tmp" \
    STUB_RUNNING_FROM="$(cd "$HERE/../../.." && pwd -P)" \
    REAL_CMP="$REAL_CMP" REAL_DIFF="$REAL_DIFF" REAL_RM="$REAL_RM" \
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
tmp_empty() { [ -z "$(ls -A "$CASE/tmp")" ]; }

# Every file under the case's root with its checksum.
root_files() { (cd "$ROOT" && find . -type f -exec cksum {} + | sort); }
# Every path under the case's root, then every file with its checksum.
root_tree() { (cd "$ROOT" && find . | sort) && root_files; }
# Whether the case's root is as new_case left it.
root_unchanged() { [ "$(root_tree)" = "$ROOT_BEFORE" ]; }

# Anything that would change the host. Only calls the stubs saw count, so a
# write the stubs did not absorb would show up in root_unchanged instead. A
# file install is `install -m`; `install -d` on a directory that exists
# changes nothing, and root_unchanged catches one that does not.
CHANGES='^(zfs (create|set|destroy|inherit|rename)|zpool (set|export|import)|docker network (create|rm)|systemctl (restart|start|stop|enable|disable|daemon-reload)|install -m|rm .*/etc/)'
changed_nothing() { not_called "$CHANGES" && root_unchanged; }

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

# A run the checks let through.
expect_success() {
  run_bootstrap
  check "succeeds" succeeded
  check "calls ufw only to read its status" only_ufw_status
}

# --- Verify failures ---------------------------------------------------------

echo "bootstrap-prod-us-east-2.sh"

new_case "not root"
echo 1000 >"$STATE/uid"
expect_check_failure root

new_case "not in a git checkout"
rm "$STATE/checkout"
expect_check_failure checkout

for elsewhere in /root/fil-one/infra-nodes /mnt/data/fil-one/infra-nodes; do
  new_case "checkout at $elsewhere"
  echo "$elsewhere" >"$STATE/checkout"
  expect_check_failure checkout
  check "names the expected location" said "belongs at /opt/fil-one/infra-nodes"
done

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

new_case "pool mounted by hand with canmount=noauto"
zfs_set data canmount noauto
expect_check_failure "pool canmount"

new_case "pool degraded"
echo DEGRADED >"$STATE/zpool-health"
expect_check_failure "pool health"

new_case "pool health unreadable"
touch "$STATE/zpool-get-fails-health"
expect_check_failure "pool health"

new_case "one mirror member"
write_pool_status nvme-FIRST_DRIVE
expect_check_failure "pool mirror"

new_case "member faulted while the pool reads ONLINE"
write_pool_status nvme-FIRST_DRIVE nvme-SECOND_DRIVE:FAULTED
expect_check_failure "pool mirror"

new_case "member named by kernel name"
write_pool_status nvme0n1 nvme-SECOND_DRIVE
expect_check_failure "pool mirror"

new_case "pool with a log device"
POOL_EXTRA='\tlogs\n\t  nvme-LOG_DRIVE          ONLINE       0     0     0\n'
write_pool_status nvme-FIRST_DRIVE nvme-SECOND_DRIVE
POOL_EXTRA=""
expect_check_failure "pool mirror"

new_case "member counting checksum errors while ONLINE"
write_pool_status nvme-FIRST_DRIVE nvme-SECOND_DRIVE:ONLINE:3
expect_check_failure "pool errors"
check "names the member and its counts" said "nvme-SECOND_DRIVE=0/0/3"

new_case "pool row counting write errors"
POOL_ROW_COUNTS="0     2     0"
write_pool_status nvme-FIRST_DRIVE nvme-SECOND_DRIVE
POOL_ROW_COUNTS=""
expect_check_failure "pool errors"
check "names the pool and its counts" said "data=0/2/0"

new_case "vdev row counting read errors"
VDEV_ROW_COUNTS="1.2K     0     0"
write_pool_status nvme-FIRST_DRIVE nvme-SECOND_DRIVE
VDEV_ROW_COUNTS=""
expect_check_failure "pool errors"
check "names the vdev and its counts" said "mirror-0=1.2K/0/0"

new_case "pool reporting data errors"
POOL_DATA_ERRORS='1 data errors, use '"'"'-v'"'"' for a list'
write_pool_status nvme-FIRST_DRIVE nvme-SECOND_DRIVE
POOL_DATA_ERRORS=""
expect_check_failure "pool errors"

new_case "pool built with another ashift"
echo 9 >"$STATE/zpool-ashift"
expect_check_failure "pool properties"

new_case "pool without autotrim"
echo off >"$STATE/zpool-autotrim"
expect_check_failure "pool properties"

for setting in compression=off atime=on xattr=on acltype=off; do
  new_case "pool with ${setting%%=*} ${setting#*=}"
  zfs_set data "${setting%%=*}" "${setting#*=}"
  expect_check_failure "pool properties"
done

new_case "pool acltype read back as posixacl"
zfs_set data acltype posixacl
expect_success

new_case "zpool status unreadable"
touch "$STATE/zpool-status-fails"
expect_check_failure "pool mirror"

new_case "pool unencrypted"
zfs_set data encryption off
expect_check_failure "pool encryption"

new_case "encryption unreadable"
touch "$STATE/get-fails-encryption"
expect_check_failure "pool encryption"

new_case "key not loaded"
zfs_set data keystatus unavailable
expect_check_failure "pool key status"

new_case "key not read from the key file"
zfs_set data keylocation prompt
expect_check_failure "pool key location"

new_case "pool size unreadable"
touch "$STATE/zpool-get-fails-size"
expect_check_failure "pool size"

new_case "key unit not enabled"
echo disabled >"$STATE/enabled-zfs-load-key-data.service"
expect_check_failure "key unit"

new_case "key unit static"
echo static >"$STATE/enabled-zfs-load-key-data.service"
expect_check_failure "key unit"

new_case "key unit file missing"
rm "$ROOT/etc/systemd/system/zfs-load-key-data.service"
ROOT_BEFORE="$(root_tree)"
expect_check_failure "key unit"

new_case "key unit without its boot dependency"
write_key_unit '[Unit]
Description=Load the ZFS encryption key for the data pool

[Service]
Type=oneshot
ExecStart=/sbin/zfs load-key data
'
ROOT_BEFORE="$(root_tree)"
expect_check_failure "key unit"
check "shows how the unit differs" said '+WantedBy=zfs-mount.service'

new_case "a drop-in replaces the key unit's ExecStart"
printf '%s\n' "{ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }" \
  >"$STATE/key-execstart"
expect_check_failure "key unit"

new_case "a drop-in ignores the key-loading command's failure"
printf '%s\n' "{ path=/bin/sh ; argv[]=/bin/sh -c $LOAD_KEY ; ignore_errors=yes ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }" \
  >"$STATE/key-execstart"
expect_check_failure "key unit"

new_case "key file does not unlock the pool"
touch "$STATE/load-key-fails"
expect_check_failure "pool key file"

new_case "Docker drop-in missing"
: >"$STATE/docker-dropins"
expect_check_failure "docker drop-in"

new_case "Docker drop-in file gone while systemd still lists it"
rm "$ROOT/etc/systemd/system/docker.service.d/10-zfs-mounted.conf"
ROOT_BEFORE="$(root_tree)"
expect_check_failure "docker drop-in"

new_case "Docker drop-in without the mount guard"
write_docker_dropin '[Unit]
Wants=zfs-mount.service
After=zfs-mount.service
'
ROOT_BEFORE="$(root_tree)"
expect_check_failure "docker drop-in"
check "shows how the drop-in differs" said '+ExecStartPre='

new_case "a later drop-in empties ExecStartPre"
printf '%s\n' /etc/systemd/system/docker.service.d/10-zfs-mounted.conf \
  /etc/systemd/system/docker.service.d/99-override.conf >"$STATE/docker-dropins"
: >"$STATE/docker-execstartpre"
expect_check_failure "docker drop-in"

new_case "a later drop-in ignores the guard's failure"
printf '%s\n' /etc/systemd/system/docker.service.d/10-zfs-mounted.conf \
  /etc/systemd/system/docker.service.d/99-override.conf >"$STATE/docker-dropins"
printf '%s\n' "{ path=/bin/sh ; argv[]=/bin/sh -c $GUARD ; ignore_errors=yes ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }" \
  >"$STATE/docker-execstartpre"
expect_check_failure "docker drop-in"

new_case "jump host address unset"
JUMP_HOST_ADDRESS_UNSET=1 expect_check_failure "jump host address"

new_case "jump host address out of range"
JUMP_ADDRESS=192.0.2.300 expect_check_failure "jump host address"

new_case "no SSH rule for the jump host"
write_ufw_status "22/tcp                     ALLOW       $OTHER"
expect_check_failure "ssh rule"

new_case "SSH rule for a network without the jump host"
write_ufw_status "22/tcp                     ALLOW       198.51.100.0/24"
expect_check_failure "ssh rule"

new_case "SSH denied from the jump host"
write_ufw_status "22/tcp                     DENY        $JUMP"
expect_check_failure "ssh rule"

new_case "SSH denied from the jump host before the rule admitting it"
write_ufw_status "Anywhere                   DENY IN     $JUMP" "22/tcp                     ALLOW       $JUMP"
expect_check_failure "ssh rule"
check "names the rule that comes first" said "Anywhere                   DENY IN     $JUMP"

new_case "SSH rejected from everywhere before the rule admitting it"
write_ufw_status "22/tcp                     REJECT      Anywhere" "22/tcp                     ALLOW       $JUMP"
expect_check_failure "ssh rule"

new_case "SSH denied on a port range before the rule admitting it"
write_ufw_status "20:30/tcp                  DENY        192.0.2.0/24" "22/tcp                     ALLOW       $JUMP"
expect_check_failure "ssh rule"

new_case "SSH denied by a rule whose comment holds an action word"
write_ufw_status "22/tcp                     DENY        $JUMP                       # was ALLOW 22" \
  "22/tcp                     ALLOW       $JUMP"
expect_check_failure "ssh rule"

new_case "rule for another port"
write_ufw_status "2222/tcp                   ALLOW       $JUMP"
expect_check_failure "ssh rule"

new_case "SSH rule admitting the jump host on one interface only"
write_ufw_status "OpenSSH on eth0            ALLOW       $JUMP/32"
expect_check_failure "ssh rule"

new_case "SSH rule admitting the jump host to one address only"
write_ufw_status "203.0.113.5 22/tcp         ALLOW       $JUMP"
expect_check_failure "ssh rule"

new_case "UFW inactive"
printf 'Status: inactive\n' >"$STATE/ufw-status"
expect_check_failure "ufw active"

new_case "filone network on another subnet"
echo 10.99.0.0/16 >"$STATE/network-subnet"
expect_check_failure "filone network"

new_case "container list unreadable"
touch "$STATE/ps-fails"
expect_check_failure "docker idle"

new_case "no daemon.json while containers run"
echo 0123456789ab >"$STATE/containers"
expect_check_failure "docker idle"

new_case "no daemon.json while stopped containers exist"
echo 0123456789ab >"$STATE/stopped-containers"
expect_check_failure "docker idle"

new_case "Docker daemon down"
touch "$STATE/daemon-down"
expect_check_failure "docker daemon"

new_case "Docker daemon down while daemon.json matches"
mkdir -p "$ROOT/etc/docker"
printf '{\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "50m",\n    "max-file": "5"\n  }\n}\n' \
  >"$ROOT/etc/docker/daemon.json"
ROOT_BEFORE="$(root_tree)"
touch "$STATE/daemon-down"
expect_check_failure "docker daemon"

# --- Accepted SSH rules ------------------------------------------------------

new_case "denials for other ports, protocols and addresses before the SSH rule"
write_ufw_status "80,443/tcp                 DENY        $JUMP" "53/udp                     DENY        Anywhere" \
  "22/tcp                     DENY        $OTHER" "Anywhere                   DENY OUT    $JUMP" \
  "22/tcp                     ALLOW       $JUMP"
expect_success

new_case "a denial after the SSH rule"
write_ufw_status "22/tcp                     ALLOW       $JUMP" "Anywhere                   DENY        Anywhere"
expect_success

new_case "SSH rule with LIMIT"
write_ufw_status "22/tcp                     LIMIT IN    $JUMP"
expect_success

new_case "SSH rule for a network holding the jump host"
write_ufw_status "22                         ALLOW IN    192.0.2.0/24"
expect_success

new_case "SSH rule by profile"
write_ufw_status "OpenSSH                    ALLOW       $JUMP/32"
expect_success

new_case "SSH rule with a comment"
write_ufw_status "22/tcp                     ALLOW       $JUMP                       # jump host DENY nothing"
expect_success

# --- A clean first run, then a second ----------------------------------------

new_case "clean first run"
run_bootstrap
check "succeeds" succeeded
check "creates control/postgres with its reservation" \
  prop_is data/fil-one/control/postgres reservation "$EXPECT_POSTGRES_RESERVATION"
check "creates control/openbao with its reservation" \
  prop_is data/fil-one/control/openbao reservation "$EXPECT_OPENBAO_RESERVATION"
check "creates control/state with its quota" \
  prop_is data/fil-one/control/state quota "$EXPECT_STATE_QUOTA"
check "creates control/caddy with its quota" \
  prop_is data/fil-one/control/caddy quota "$EXPECT_CADDY_QUOTA"
check "creates control/alloy with its quota" \
  prop_is data/fil-one/control/alloy quota "$EXPECT_ALLOY_QUOTA"
check "creates piri with its quota" \
  prop_is data/fil-one/piri quota "$EXPECT_PIRI_QUOTA"
check "creates ingot/segments with its quota" \
  prop_is data/fil-one/ingot/segments quota "$EXPECT_SEGMENTS_QUOTA"
check "creates ingot/blobs with its quota" \
  prop_is data/fil-one/ingot/blobs quota "$EXPECT_BLOBS_QUOTA"
check "tries the key file without loading it" called '^zfs load-key -n data$'
check "creates exactly eight datasets" \
  test "$(grep -c '^zfs create' "$STATE/calls")" -eq 8
check "checks where the blobs dataset mounted" called '^zfs get .*mountpoint data/fil-one/ingot/blobs$'
check "writes daemon.json with json-file rotation" \
  grep -q '"log-driver": "json-file"' "$ROOT/etc/docker/daemon.json"
check "restarts Docker for the new daemon.json" called '^systemctl restart docker'
check "creates the filone network" called '^docker network create --subnet 172\.18\.0\.0/16 filone'
check "writes node.conf for prod/us-east-2" grep -qx 'FILONE_NODE=prod/us-east-2' "$ROOT/etc/fil-one/node.conf"
check "node.conf tracks main" grep -qx 'FILONE_GIT_REF=main' "$ROOT/etc/fil-one/node.conf"
check "node.conf names the checkout" grep -qx 'FILONE_CHECKOUT=/opt/fil-one/infra-nodes' "$ROOT/etc/fil-one/node.conf"
check "writes the tmpfiles.d entries" grep -qx 'd /run/fil-one/secrets 0700 root root -' "$ROOT/etc/tmpfiles.d/filone.conf"
check "creates the secrets tmpfs directory" test -d "$ROOT/run/fil-one/secrets"
check "installs the systemd units" test -f "$ROOT/etc/systemd/system/filone-reconcile.timer"
check "does not enable any unit" not_called '^systemctl enable'
check "writes the completion stamp" test -s "$ROOT/etc/fil-one/bootstrap-complete"
check "prints the Ingot blob budget" printed "INGOT_LOCAL_BLOB_MAX_BYTES=$EXPECT_BLOB_BUDGET"
check "leaves no temporary file" tmp_empty
check "calls ufw only to read its status" only_ufw_status

current="second run"
: >"$STATE/calls"
before="$(root_files)"
run_bootstrap
check "succeeds" succeeded
check "changes nothing" not_called "$CHANGES"
check "leaves every file as it was, the stamp included" test "$(root_files)" = "$before"
check "still prints the Ingot blob budget" printed "INGOT_LOCAL_BLOB_MAX_BYTES=$EXPECT_BLOB_BUDGET"
check "calls ufw only to read its status" only_ufw_status

current="daemon.json matches while containers run"
: >"$STATE/calls"
echo 0123456789ab >"$STATE/containers"
run_bootstrap
check "succeeds" succeeded
check "changes nothing" not_called "$CHANGES"

# --- daemon.json someone else wrote ------------------------------------------

new_case "daemon.json with other settings"
mkdir -p "$ROOT/etc/docker"
printf '{"data-root": "/srv/docker", "iptables": false}\n' >"$ROOT/etc/docker/daemon.json"
run_bootstrap
check "exits non-zero" failed
check "names the check 'docker log config'" said "check 'docker log config' failed"
check "shows how the file differs" said '"data-root": "/srv/docker"'
check "leaves daemon.json as it was" \
  grep -qx '{"data-root": "/srv/docker", "iptables": false}' "$ROOT/etc/docker/daemon.json"
check "changes nothing" not_called "$CHANGES"
check "calls ufw only to read its status" only_ufw_status

# --- Datasets ----------------------------------------------------------------

new_case "datasets with other values beside missing ones"
zfs_set data/fil-one/ingot/blobs quota 1000000
zfs_set data/fil-one/control/postgres reservation 2000000
run_bootstrap
check "exits non-zero" failed
check "reports the blobs quota" said "data/fil-one/ingot/blobs: quota is 1000000, expected $EXPECT_BLOBS_QUOTA"
check "reports the postgres reservation as well" \
  said "data/fil-one/control/postgres: reservation is 2000000, expected $EXPECT_POSTGRES_RESERVATION"
check "leaves the blobs quota alone" prop_is data/fil-one/ingot/blobs quota 1000000
check "leaves the postgres reservation alone" prop_is data/fil-one/control/postgres reservation 2000000
check "creates none of the missing ones" not_called '^zfs create'
check "changes nothing" changed_nothing
check "calls ufw only to read its status" only_ufw_status

new_case "data/fil-one mounted elsewhere"
zfs_set data/fil-one mountpoint /srv/fil-one
run_bootstrap
check "exits non-zero" failed
check "reports the mount point" said "data/fil-one: mountpoint is /srv/fil-one, expected /mnt/data/fil-one"
check "changes nothing" changed_nothing

new_case "existing parent dataset unmounted beside missing ones"
zfs_set data/fil-one mountpoint /mnt/data/fil-one
zfs_set data/fil-one mounted yes
zfs_set data/fil-one/control mounted no
run_bootstrap
check "exits non-zero" failed
check "reports the unmounted parent" said "data/fil-one/control: mounted is no, expected yes"
check "creates none of the missing ones" not_called '^zfs create'
check "changes nothing" changed_nothing

new_case "existing dataset with an encryption root of its own"
zfs_set data/fil-one/control/state quota "$EXPECT_STATE_QUOTA"
zfs_set data/fil-one/control/state mounted yes
zfs_set data/fil-one/control/state encryptionroot data/fil-one/control/state
run_bootstrap
check "exits non-zero" failed
check "reports the encryption root" \
  said "data/fil-one/control/state: encryptionroot is data/fil-one/control/state, expected data"
check "creates none of the missing ones" not_called '^zfs create'
check "changes nothing" changed_nothing

new_case "existing dataset mounted by hand with canmount=noauto"
zfs_set data/fil-one/control/state quota "$EXPECT_STATE_QUOTA"
zfs_set data/fil-one/control/state mounted yes
zfs_set data/fil-one/control/state canmount noauto
run_bootstrap
check "exits non-zero" failed
check "reports canmount" said "data/fil-one/control/state: canmount is noauto, expected on"
check "creates none of the missing ones" not_called '^zfs create'
check "changes nothing" changed_nothing

new_case "existing parent dataset mounted by hand with canmount=noauto"
zfs_set data/fil-one mounted yes
zfs_set data/fil-one canmount noauto
run_bootstrap
check "exits non-zero" failed
check "reports canmount" said "data/fil-one: canmount is noauto, expected on"
check "changes nothing" changed_nothing

for property in quota reservation; do
  for dataset in data data/fil-one data/fil-one/ingot; do
    new_case "$dataset with a $property"
    zfs_set "$dataset" mounted yes
    zfs_set "$dataset" "$property" 1000000
    run_bootstrap
    check "exits non-zero" failed
    check "reports the $property" said "$dataset: $property is 1000000, expected 0"
    check "leaves the $property alone" prop_is "$dataset" "$property" 1000000
    check "creates none of the missing ones" not_called '^zfs create'
    check "changes nothing" changed_nothing
  done
done

new_case "created datasets that do not mount"
touch "$STATE/create-unmounted"
run_bootstrap
check "exits non-zero" failed
check "names the check 'datasets mounted'" said "check 'datasets mounted' failed"
check "goes no further than the datasets" not_called '^systemctl restart'

new_case "Docker restart fails"
touch "$STATE/restart-fails"
run_bootstrap
check "exits non-zero" failed
check "names the check 'docker restart'" said "check 'docker restart' failed"

# --- The node directory ------------------------------------------------------

# nodes/prod/us-east-2 binds the datasets this script creates. Read statically,
# without docker: every bind in its compose files is written as a source line
# followed by its target line.
NODE_DIR="$HERE/../../../nodes/prod/us-east-2"

new_case "the node directory matches the datasets"
run_bootstrap
check "succeeds" succeeded
# Each dataset the run created, as the mount point bootstrap checked it at.
mounts="$(sed -nE 's#^zfs create .* data/(fil-one/[^ ]+)$#/mnt/data/\1#p' "$STATE/calls")"
# One line per bind: project, source, target.
binds="$(for project in platform apps; do
  awk -v project="$project" '
    $1 == "source:" { source = $2; next }
    $1 == "target:" && source != "" { print project " " source " " $2 }
    { source = "" }
  ' "$NODE_DIR/$project/compose.yml"
done)"
bind_source() { # bind_source <project> <target>: the source bound at that target
  awk -v project="$1" -v target="$2" '$1 == project && $3 == target { print $2 }' <<<"$binds"
}
mount_of() { # mount_of <path>: the created dataset whose mount point holds it
  local mount best=""
  for mount in $mounts; do
    case "$1/" in "$mount"/*) [ "${#mount}" -le "${#best}" ] || best="$mount" ;; esac
  done
  printf '%s' "$best"
}
node_value() { sed -nE "s/^$1=(.*)$/\\1/p" "$NODE_DIR/node.env" | tail -1; }

check "node.env's control directory is the control datasets' parent" \
  test "$(node_value FILONE_CONTROL_DIR)" = /mnt/data/fil-one/control
check "node.env has filone_init require control/state to be mounted" \
  test "$(node_value FILONE_STATE_DIR_IS_MOUNT)" = true
check "node.env's data directory is the Ingot datasets' parent" \
  test "$(node_value FILONE_DATA_DIR)" = /mnt/data/fil-one/ingot
check "Postgres is bound to control/postgres" \
  test "$(mount_of "$(bind_source platform /var/lib/postgresql)")" = /mnt/data/fil-one/control/postgres
check "OpenBao is bound to control/openbao" \
  test "$(mount_of "$(bind_source platform /openbao/file)")" = /mnt/data/fil-one/control/openbao
check "the status document is served from control/state" \
  test "$(mount_of "$(bind_source platform /srv/filone/.well-known)")" = /mnt/data/fil-one/control/state
check "the deploy stamps are read from control/state" \
  test "$(mount_of "$(bind_source platform /metrics)")" = /mnt/data/fil-one/control/state
check "Caddy's certificates are on control/caddy" \
  test "$(mount_of "$(bind_source platform /data)")" = /mnt/data/fil-one/control/caddy
check "Caddy's autosaved config is on control/caddy" \
  test "$(mount_of "$(bind_source platform /config)")" = /mnt/data/fil-one/control/caddy
check "Alloy's write-ahead log is control/alloy" \
  test "$(bind_source platform /var/lib/alloy/data)" = /mnt/data/fil-one/control/alloy
check "the Piri is bound to a directory on the piri dataset" \
  test "$(mount_of "$(bind_source apps /data/piri)")" = /mnt/data/fil-one/piri
check "the Piri's directory is below the dataset's mount point" \
  test "$(bind_source apps /data/piri)" != /mnt/data/fil-one/piri
check "Ingot's data directory is ingot/blobs" \
  test "$(bind_source apps /data)" = /mnt/data/fil-one/ingot/blobs
check "Ingot's segments are ingot/segments" \
  test "$(bind_source apps /data/segments)" = /mnt/data/fil-one/ingot/segments
# Every bind from /mnt, named above or not, lies on a dataset the run created
# rather than on a parent such as control, which has no quota of its own.
off_dataset=""
while read -r _ source _; do
  case "$source" in /mnt/*) ;; *) continue ;; esac
  [ -n "$(mount_of "$source")" ] || off_dataset="$off_dataset $source"
done <<<"$binds"
check "binds nothing from /mnt outside the created datasets" test -z "$off_dataset"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
