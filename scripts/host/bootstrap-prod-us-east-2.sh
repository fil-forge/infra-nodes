#!/usr/bin/env bash
# Prepare the IST-1 host for the prod/us-east-2 FilOne appliance.
#
# One host, as with bootstrap-staging-eu-central-3.sh: the pool, the dataset
# layout and the checks below are this machine's, and another node gets a
# script of its own.
#
# Run as root from the node's checkout, once before anything holds state and
# again whenever in doubt. A second run changes nothing:
#
#   JUMP_HOST_ADDRESS=<jump host address> scripts/host/bootstrap-prod-us-east-2.sh
#
# The host arrives with its ZFS pool built, its key unit and Docker drop-in in
# place, and SSH admitted from the jump host only, all as
# docs/decisions/2026-11-ist1-appliance-storage.md records. Section 1 checks
# all of that, and everything the later sections would refuse, before
# anything changes; a failed check stops the run and names itself. Section 2
# creates the node's datasets, section 3 sets Docker's log rotation, and
# section 4 does what the staging bootstrap does for FilOne's own paths,
# network, node.conf and units.
#
# It never adds, removes or reorders a firewall rule. The host has no
# out-of-band console, so a lost SSH rule leaves a provider ticket as the only
# way back in. UFW does not filter ports Docker publishes; the node's compose
# files decide those.
#
# It does not enable the timers: provision-platform.sh needs to run first, and
# the runbook enables them after it.
#
# Files under /etc are read only through cmp and diff, and written only through
# install and rm, which is what lets the test in tests/ run it against stubs.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

CHECKOUT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
NODE=prod/us-east-2
POOL=data
POOL_MOUNTPOINT=/mnt/data
POOL_KEYLOCATION=file:///etc/zfs/keys/data.key
KEY_UNIT=zfs-load-key-data.service
DOCKER_DROPIN=/etc/systemd/system/docker.service.d/10-zfs-mounted.conf
DAEMON_JSON=/etc/docker/daemon.json
STAMP=/etc/fil-one/bootstrap-complete
# The same fixed subnet as staging. Nothing on this host filters by it today;
# it is fixed so that a later rule can.
FILONE_SUBNET=172.18.0.0/16

MIB=1048576
GIB=$((1024 * MIB))

fail() { die "check '$1' failed: $2"; }

# Compare stdin with a file: prints same, differs or absent. cmp exits 2 when
# it cannot read the file, which for root means it is not there.
compare_file() {
  local status=0
  cmp -s - "$1" || status=$?
  case "$status" in
    0) echo same ;;
    1) echo differs ;;
    *) echo absent ;;
  esac
}

# Install stdin at a path, mode 0644, unless the path already holds exactly
# that. Says so when it writes.
install_if_changed() {
  local destination="$1" tmp
  tmp="$(mktemp)" || die "mktemp failed"
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    die "could not write $tmp"
  fi
  if ! cmp -s "$tmp" "$destination"; then
    if ! install -m 0644 "$tmp" "$destination"; then
      rm -f "$tmp"
      die "could not write $destination"
    fi
    echo "  wrote $destination"
  fi
  rm -f "$tmp"
}

ipv4_to_int() { # prints the address as a number, or fails
  local IFS=. a b c d octet
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -r a b c d <<<"$1"
  for octet in "$a" "$b" "$c" "$d"; do
    [ "$((10#$octet))" -le 255 ] || return 1
  done
  echo $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

# Whether an address is inside an address or network as UFW prints it.
in_network() { # in_network <address> <address[/prefix]>
  local address network prefix=32 mask
  address="$(ipv4_to_int "$1")" || return 1
  case "$2" in */*) prefix="${2#*/}" ;; esac
  [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
  [ "$prefix" -le 32 ] || return 1
  network="$(ipv4_to_int "${2%/*}")" || return 1
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  [ $((address & mask)) -eq $((network & mask)) ]
}

# Docker's log rotation: json-file for every container this Docker creates.
# A change applies only to containers created after the restart, so it is made
# before the first one exists.
daemon_json() {
  cat <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
JSON
}

# --- 1. Verify, changing nothing ---------------------------------------------

[ "$(id -u)" -eq 0 ] || fail root "must run as root"
[ -e "$CHECKOUT/.git" ] || fail checkout "expected a git checkout at $CHECKOUT"

# The address SSH is admitted from. Read at run time rather than committed:
# this repository is public.
[ -n "${JUMP_HOST_ADDRESS:-}" ] ||
  fail "jump host address" "set JUMP_HOST_ADDRESS to the jump host's public IPv4 address"
ipv4_to_int "$JUMP_HOST_ADDRESS" >/dev/null ||
  fail "jump host address" "JUMP_HOST_ADDRESS is '$JUMP_HOST_ADDRESS', not an IPv4 address"

command -v docker >/dev/null || fail docker "docker is not installed"
# deploy-apps.sh runs `pull --policy missing`, and 2.40 is the oldest Compose
# verified to have it. Only the major and minor are compared, as on staging.
compose_version="$(docker compose version --short 2>/dev/null)" ||
  fail "compose version" "the docker compose plugin is not installed"
[[ "$compose_version" =~ ^v?([0-9]+)\.([0-9]+) ]] ||
  fail "compose version" "cannot read the Compose version from '$compose_version'"
if [ "${BASH_REMATCH[1]}" -lt 2 ] ||
  { [ "${BASH_REMATCH[1]}" -eq 2 ] && [ "${BASH_REMATCH[2]}" -lt 40 ]; }; then
  fail "compose version" "Docker Compose $compose_version is installed; FilOne needs 2.40 or later"
fi

zpool list -H -o name "$POOL" >/dev/null 2>&1 ||
  fail "pool imported" "pool '$POOL' is not imported"

# A pool property, failing the named check when zfs cannot read it.
pool_value() { # pool_value <check> <property>
  zfs get -H -o value "$2" "$POOL" || fail "$1" "cannot read $2 of $POOL"
}

value="$(pool_value "pool mountpoint" mountpoint)"
[ "$value" = "$POOL_MOUNTPOINT" ] ||
  fail "pool mountpoint" "$POOL is mounted at '$value', expected $POOL_MOUNTPOINT"
value="$(pool_value "pool mounted" mounted)"
[ "$value" = yes ] || fail "pool mounted" "$POOL is not mounted"

value="$(zpool get -H -o value health "$POOL")" ||
  fail "pool health" "cannot read the health of $POOL"
[ "$value" = ONLINE ] || fail "pool health" "$POOL is $value, expected ONLINE"

# One mirror of two ONLINE drives, each named by /dev/disk/by-id, and nothing
# else. zpool status indents the config by two spaces per level after a tab:
# the pool, its top-level vdevs, then their members. Sections such as logs,
# cache, special or spares sit at the pool's level after the pool's own tree.
status="$(zpool status "$POOL")" || fail "pool mirror" "cannot read zpool status $POOL"
layout="$(awk -v pool="$POOL" '
  /^\tNAME/ { in_config = 1; next }
  in_config && /^$/ { in_config = 0 }
  !in_config { next }
  /^\t[^ \t]/ { section = $1; if (section != pool) extra = extra " " section; next }
  section != pool { next }
  /^\t  [^ ]/ { vdevs++; vdev = $1 }
  /^\t    [^ ]/ {
    members++
    if ($2 != "ONLINE") bad = bad " " $1 "=" $2
    if ($1 ~ /^(nvme[0-9]+n[0-9]+|sd[a-z]+)/) kernel = kernel " " $1
  }
  END { printf "%d|%s|%d|%s|%s|%s\n", vdevs, vdev, members, bad, kernel, extra }
' <<<"$status")"
IFS='|' read -r vdevs vdev members bad kernel extra <<<"$layout"
{ [ "$vdevs" = 1 ] && [[ "$vdev" == mirror-* ]] && [ "$members" = 2 ]; } ||
  fail "pool mirror" "$POOL should be one mirror of two drives; zpool status shows $vdevs top-level vdev(s), the last '$vdev', with $members member(s)"
[ -z "$bad" ] || fail "pool mirror" "mirror members not ONLINE:$bad"
[ -z "$kernel" ] ||
  fail "pool mirror" "members named by kernel name, which can change between boots:$kernel"
[ -z "$extra" ] ||
  fail "pool mirror" "$POOL has devices outside its mirror, which the storage record does not describe:$extra"

value="$(pool_value "pool encryption" encryption)"
[ "$value" = aes-256-gcm ] || fail "pool encryption" "$POOL encryption is '$value', expected aes-256-gcm"
value="$(pool_value "pool key status" keystatus)"
[ "$value" = available ] || fail "pool key status" "$POOL key status is '$value', expected available"
value="$(pool_value "pool key location" keylocation)"
[ "$value" = "$POOL_KEYLOCATION" ] ||
  fail "pool key location" "$POOL key location is '$value', expected $POOL_KEYLOCATION; the key would not load at boot"

# Sizes come from the pool's size, which `zpool get size` reports as a fixed
# number of bytes for a mirror, so every run computes the same values.
pool_size="$(zpool get -Hp -o value size "$POOL")" ||
  fail "pool size" "cannot read the size of $POOL"
[[ "$pool_size" =~ ^[0-9]+$ ]] || fail "pool size" "cannot read the size of $POOL from '$pool_size'"

systemctl is-enabled "$KEY_UNIT" >/dev/null 2>&1 ||
  fail "key unit" "$KEY_UNIT is not enabled, so the pool would stay locked after a reboot"
grep -qxF "$DOCKER_DROPIN" <<<"$(systemctl show -p DropInPaths --value docker.service | tr ' ' '\n')" ||
  fail "docker drop-in" "systemd does not load $DOCKER_DROPIN for docker.service, so Docker could start before the pool mounts"

command -v ufw >/dev/null || fail "ufw active" "ufw is not installed"
ufw_status="$(ufw status)" || fail "ufw active" "could not read ufw status"
grep -qx 'Status: active' <<<"$ufw_status" || fail "ufw active" "ufw is not active"
# Port 22 from the jump host: `22`, `22/tcp` or the OpenSSH profile, optionally
# on one interface or to one destination address, allowed or rate-limited,
# from the address itself or a network that holds it.
ssh_rule='^([0-9./]+ )?(22(/tcp)?|OpenSSH)( on [^ ]+)? +(ALLOW|LIMIT)( IN)? +([0-9.]+(/[0-9]+)?)( |$)'
ssh_admitted=0
while IFS= read -r line; do
  [[ "$line" =~ $ssh_rule ]] || continue
  ! in_network "$JUMP_HOST_ADDRESS" "${BASH_REMATCH[7]}" || ssh_admitted=1
done <<<"$ufw_status"
[ "$ssh_admitted" -eq 1 ] ||
  fail "ssh rule" "no UFW rule admits port 22 from $JUMP_HOST_ADDRESS. This script changes no firewall rule; fix it by hand, keeping your current session open"

# An existing filone network must be the one staging uses.
if docker network inspect filone >/dev/null 2>&1; then
  actual_subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' filone)" ||
    fail "filone network" "cannot read the subnet of the filone network"
  [ "$actual_subnet" = "$FILONE_SUBNET" ] ||
    fail "filone network" "the filone network uses $actual_subnet, expected $FILONE_SUBNET"
fi

# daemon.json is written only where none exists. A file someone else wrote may
# hold settings of theirs, so a different one is shown and left alone rather
# than replaced. Writing means restarting Docker, so it needs Docker idle.
daemon_json_state="$(daemon_json | compare_file "$DAEMON_JSON")"
case "$daemon_json_state" in
  differs)
    daemon_json | diff -u "$DAEMON_JSON" - >&2 || true
    fail "docker log config" "$DAEMON_JSON differs from the log rotation above. Merge the rotation into it by hand and restart Docker, then run this again"
    ;;
  absent)
    running="$(docker ps -q)" ||
      fail "docker idle" "cannot list containers, so cannot tell whether restarting Docker is safe"
    [ -z "$running" ] ||
      fail "docker idle" "$DAEMON_JSON needs writing and Docker restarting, but containers are running. Stop them first"
    ;;
esac

# The datasets, and the one property each sets. Following the appliance layout
# RFC's fast pool: control state is reserved or capped, Ingot's two are capped.
#
# piri holds what piri init writes and the config provision-apps.sh renders;
# its blobs go to object storage.
#
# nodes/prod/us-east-2 (a later change) binds these mount points, under
# /mnt/data/fil-one, into the containers. Two things there depend on this
# layout. Its node.env sets FILONE_CONTROL_DIR=/mnt/data/fil-one/control and
# a FILONE_DATA_DIR under /mnt/data/fil-one, as staging's does, because
# lib.sh's defaults are the cloud nodes' /mnt/fil-one paths and filone_init
# refuses to run when the control directory is not a mount. And Ingot keeps
# segments, spool and cache under one data directory, so its compose file
# binds segments from ingot/segments and spool and cache from ingot/blobs.
percent() { echo $((pool_size * $1 / 100 / MIB * MIB)); }
blobs_quota="$(percent 50)"
datasets="
control/postgres reservation $(percent 20)
control/openbao reservation $((10 * GIB))
control/state quota $((50 * GIB))
piri quota $((50 * GIB))
ingot/segments quota $(percent 5)
ingot/blobs quota $blobs_quota
"
# The datasets zfs create -p makes on the way, which set nothing of their own.
parents="fil-one fil-one/control fil-one/ingot"

dataset_value() { # dataset_value <property> <dataset>
  zfs get -Hp -o value "$1" "$2" || fail datasets "cannot read $1 of $2"
}

# An existing dataset is never changed: a smaller quota on one that holds data
# is not something to apply unattended. Every difference is reported before
# the run stops, and nothing is created while any remains.
mismatches=0
mismatch() { # mismatch <dataset> <property> <actual> <expected>
  echo "ERROR: $1: $2 is $3, expected $4" >&2
  mismatches=$((mismatches + 1))
}
for name in $parents; do
  dataset="$POOL/$name"
  zfs list -H -o name "$dataset" >/dev/null 2>&1 || continue
  actual="$(dataset_value mountpoint "$dataset")"
  [ "$actual" = "$POOL_MOUNTPOINT/$name" ] ||
    mismatch "$dataset" mountpoint "$actual" "$POOL_MOUNTPOINT/$name"
done
while read -r name property want; do
  [ -n "$name" ] || continue
  dataset="$POOL/fil-one/$name"
  zfs list -H -o name "$dataset" >/dev/null 2>&1 || continue
  # Its other size property must be none, which zfs get -p reads as 0.
  for check_property in quota reservation; do
    expected=0
    [ "$check_property" != "$property" ] || expected="$want"
    actual="$(dataset_value "$check_property" "$dataset")"
    [ "$actual" = "$expected" ] || mismatch "$dataset" "$check_property" "$actual" "$expected"
  done
  actual="$(dataset_value mountpoint "$dataset")"
  [ "$actual" = "$POOL_MOUNTPOINT/fil-one/$name" ] ||
    mismatch "$dataset" mountpoint "$actual" "$POOL_MOUNTPOINT/fil-one/$name"
done <<<"$datasets"
[ "$mismatches" -eq 0 ] ||
  fail datasets "$mismatches dataset value(s) differ from this script's and were left alone.
       Change them by hand with 'zfs set', or change this script, then run it again."

# --- 2. Datasets -------------------------------------------------------------

while read -r name property want; do
  [ -n "$name" ] || continue
  dataset="$POOL/fil-one/$name"
  zfs list -H -o name "$dataset" >/dev/null 2>&1 && continue
  echo "  creating $dataset ($property $want)"
  zfs create -p -o "$property=$want" "$dataset" || fail datasets "could not create $dataset"
done <<<"$datasets"

# Each one where the bind mounts will look for it, and mounted there, so that
# nothing lands on the pool's root dataset instead.
for name in $parents $(awk 'NF { print "fil-one/" $1 }' <<<"$datasets"); do
  dataset="$POOL/$name"
  actual="$(dataset_value mountpoint "$dataset")"
  [ "$actual" = "$POOL_MOUNTPOINT/$name" ] ||
    fail "datasets mounted" "$dataset is at '$actual', expected $POOL_MOUNTPOINT/$name"
  [ "$(dataset_value mounted "$dataset")" = yes ] ||
    fail "datasets mounted" "$dataset is not mounted"
done

# --- 3. Docker's log rotation ------------------------------------------------

if [ "$daemon_json_state" = absent ]; then
  install -d -m 0755 /etc/docker
  daemon_json | install_if_changed "$DAEMON_JSON"
  echo "  restarting Docker"
  systemctl restart docker.service ||
    fail "docker restart" "Docker did not restart with the new $DAEMON_JSON"
  docker info >/dev/null || fail "docker restart" "Docker did not come back after the restart"
fi

# --- 4. FilOne's paths, network, node.conf and units -------------------------

install -d -m 0700 /run/fil-one /run/fil-one/secrets /run/fil-one/bao
install -d -m 0755 /etc/fil-one /etc/tmpfiles.d
install_if_changed /etc/tmpfiles.d/filone.conf <<'TMPFILES'
d /run/fil-one 0700 root root -
d /run/fil-one/secrets 0700 root root -
d /run/fil-one/bao 0700 root root -
TMPFILES

# Section 1 checked the subnet of one that exists.
docker network inspect filone >/dev/null 2>&1 ||
  docker network create --subnet "$FILONE_SUBNET" filone ||
  fail "filone network" "could not create the filone network"

# filone_init reads this and then nodes/$NODE/node.env, which a later change
# adds; until then the deploy scripts stop at the missing node directory.
install_if_changed /etc/fil-one/node.conf <<CONF
FILONE_NODE=$NODE
FILONE_CHECKOUT=$CHECKOUT
FILONE_GIT_REF=main
CONF

FILONE_CHECKOUT="$CHECKOUT"
sync_systemd_units

# When bootstrap first finished. Written once, so a later run changes nothing.
if [ "$(compare_file "$STAMP" </dev/null)" = absent ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ | install_if_changed "$STAMP"
fi

# The node.env of the later change commits this value, so it is printed rather
# than written: 80% of the blobs quota, leaving room above the budget for
# bodies in flight and under the 10%-free alert.
echo "prod/us-east-2 bootstrap complete"
echo "Set this in nodes/$NODE/node.env:"
echo "  INGOT_LOCAL_BLOB_MAX_BYTES=$((blobs_quota * 80 / 100))"
