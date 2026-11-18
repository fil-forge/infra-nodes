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
# docs/decisions/2026-11-ist1-appliance-storage.md records. This script checks
# all of that first and stops, naming the check, before it changes anything.
# It then creates the node's datasets, sets Docker's log rotation, and does
# what the staging bootstrap does for FilOne's own paths, network, node.conf
# and units.
#
# It never adds, removes or reorders a firewall rule. The host has no
# out-of-band console, so a lost SSH rule leaves a provider ticket as the only
# way back in. UFW does not filter ports Docker publishes; the node's compose
# files decide those.
#
# It does not enable the timers: provision-platform.sh needs to run first, and
# the runbook enables them after it.
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
# The same fixed subnet as staging. Nothing on this host filters by it today;
# it is fixed so that a later rule can.
FILONE_SUBNET=172.18.0.0/16

MIB=1048576
GIB=$((1024 * MIB))

fail() { die "check '$1' failed: $2"; }

# Install stdin at a path, mode 0644, when the path does not already hold
# exactly that. Returns 1 when it did, so a caller can tell a change from none.
install_if_changed() {
  local destination="$1" tmp
  tmp="$(mktemp)" || die "mktemp failed"
  cat >"$tmp" || die "could not write $tmp"
  if cmp -s "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi
  install -m 0644 "$tmp" "$destination" || die "could not write $destination"
  rm -f "$tmp"
}

# --- 1. Verify, changing nothing ---------------------------------------------

[ "$(id -u)" -eq 0 ] || fail root "must run as root"
[ -e "$CHECKOUT/.git" ] || fail checkout "expected a git checkout at $CHECKOUT"

# The address SSH is admitted from. Read at run time rather than committed:
# this repository is public.
[ -n "${JUMP_HOST_ADDRESS:-}" ] ||
  fail "jump host address" "set JUMP_HOST_ADDRESS to the jump host's public IPv4 address"
[[ "$JUMP_HOST_ADDRESS" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
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

zfs_value() { zfs get -H -o value "$1" "$2"; }

value="$(zfs_value mountpoint "$POOL")"
[ "$value" = "$POOL_MOUNTPOINT" ] ||
  fail "pool mountpoint" "$POOL is mounted at '$value', expected $POOL_MOUNTPOINT"
value="$(zfs_value mounted "$POOL")"
[ "$value" = yes ] || fail "pool mounted" "$POOL is not mounted"

value="$(zpool get -H -o value health "$POOL")"
[ "$value" = ONLINE ] || fail "pool health" "$POOL is $value, expected ONLINE"

# One mirror of two ONLINE drives, each named by /dev/disk/by-id. zpool status
# indents the config by two spaces per level after a tab: the pool, its
# top-level vdevs, then their members. Sections such as logs or cache sit at
# the pool's level and end the pool's own tree.
layout="$(zpool status "$POOL" | awk -v pool="$POOL" '
  /^\tNAME/ { in_config = 1; next }
  in_config && /^$/ { in_config = 0 }
  !in_config { next }
  /^\t[^ \t]/ { section = $1; next }
  section != pool { next }
  /^\t  [^ ]/ { vdevs++; vdev = $1 }
  /^\t    [^ ]/ {
    members++
    if ($2 != "ONLINE") bad = bad " " $1 "=" $2
    if ($1 ~ /^(nvme[0-9]+n[0-9]+|sd[a-z]+)/) kernel = kernel " " $1
  }
  END { printf "%d|%s|%d|%s|%s\n", vdevs, vdev, members, bad, kernel }
')"
IFS='|' read -r vdevs vdev members bad kernel <<<"$layout"
{ [ "$vdevs" = 1 ] && [[ "$vdev" == mirror-* ]] && [ "$members" = 2 ]; } ||
  fail "pool mirror" "$POOL should be one mirror of two drives; zpool status shows $vdevs top-level vdev(s), the last '$vdev', with $members member(s)"
[ -z "$bad" ] || fail "pool mirror" "mirror members not ONLINE:$bad"
[ -z "$kernel" ] ||
  fail "pool mirror" "members named by kernel name, which can change between boots:$kernel"

value="$(zfs_value encryption "$POOL")"
[ "$value" = aes-256-gcm ] || fail "pool encryption" "$POOL encryption is '$value', expected aes-256-gcm"
value="$(zfs_value keystatus "$POOL")"
[ "$value" = available ] || fail "pool key status" "$POOL key status is '$value', expected available"
value="$(zfs_value keylocation "$POOL")"
[ "$value" = "$POOL_KEYLOCATION" ] ||
  fail "pool key location" "$POOL key location is '$value', expected $POOL_KEYLOCATION; the key would not load at boot"

systemctl is-enabled "$KEY_UNIT" >/dev/null 2>&1 ||
  fail "key unit" "$KEY_UNIT is not enabled, so the pool would stay locked after a reboot"
grep -qxF "$DOCKER_DROPIN" <<<"$(systemctl show -p DropInPaths --value docker.service | tr ' ' '\n')" ||
  fail "docker drop-in" "systemd does not load $DOCKER_DROPIN for docker.service, so Docker could start before the pool mounts"

command -v ufw >/dev/null || fail "ufw active" "ufw is not installed"
ufw_status="$(ufw status)" || fail "ufw active" "could not read ufw status"
grep -qx 'Status: active' <<<"$ufw_status" || fail "ufw active" "ufw is not active"
# Port 22 from the jump host: `22`, `22/tcp` or the OpenSSH profile, optionally
# on one interface or to one destination address, from the address or its /32.
jump_pattern="${JUMP_HOST_ADDRESS//./\\.}"
grep -qE "^([0-9.]+ )?(22(/tcp)?|OpenSSH)( on [^ ]+)? +ALLOW( IN)? +$jump_pattern(/32)?( |$)" <<<"$ufw_status" ||
  fail "ssh rule" "no UFW rule admits port 22 from $JUMP_HOST_ADDRESS. This script changes no firewall rule; fix it by hand, keeping your current session open"

# json-file with rotation, for every container this Docker creates. A change
# applies only to containers created after the restart, so it is made before
# the first one exists.
daemon_json="$(mktemp)"
cat >"$daemon_json" <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
JSON
daemon_json_current=0
cmp -s "$daemon_json" "$DAEMON_JSON" && daemon_json_current=1
if [ "$daemon_json_current" -eq 0 ] && [ -n "$(docker ps -q)" ]; then
  rm -f "$daemon_json"
  fail "docker log config" "$DAEMON_JSON needs writing and Docker restarting, but containers are running. Stop them first, or leave the file as it is"
fi

# --- 2. Datasets -------------------------------------------------------------

# Sizes come from the pool's size, which `zpool get size` reports as a fixed
# number of bytes for a mirror, so every run computes the same values.
pool_size="$(zpool get -Hp -o value size "$POOL")"
[[ "$pool_size" =~ ^[0-9]+$ ]] || die "cannot read the size of $POOL from '$pool_size'"
percent() { echo $((pool_size * $1 / 100 / MIB * MIB)); }

blobs_quota="$(percent 50)"
# The datasets, and the one property each sets. Following the appliance layout
# RFC's fast pool: control state is reserved or capped, Ingot's two are capped.
#
# piri holds what piri init writes and the config provision-apps.sh renders;
# its blobs go to object storage. nodes/prod/us-east-2 (a later change) binds
# these mount points, under /mnt/data/fil-one, into the containers.
datasets="
control/postgres reservation $(percent 20)
control/openbao reservation $((10 * GIB))
control/state quota $((50 * GIB))
piri quota $((50 * GIB))
ingot/segments quota $(percent 5)
ingot/blobs quota $blobs_quota
"

mismatches=0
while read -r name property want; do
  [ -n "$name" ] || continue
  dataset="$POOL/fil-one/$name"
  if zfs list -H -o name "$dataset" >/dev/null 2>&1; then
    # An existing dataset is never changed: a smaller quota on one that holds
    # data is not something to apply unattended. Its other size property must
    # still be none, which zfs get -p reads as 0.
    for check_property in quota reservation; do
      expected=0
      [ "$check_property" != "$property" ] || expected="$want"
      actual="$(zfs get -Hp -o value "$check_property" "$dataset")"
      if [ "$actual" != "$expected" ]; then
        echo "ERROR: $dataset: $check_property is $actual, expected $expected" >&2
        mismatches=$((mismatches + 1))
      fi
    done
  else
    echo "  creating $dataset ($property $want)"
    zfs create -p -o "$property=$want" "$dataset"
  fi
done <<<"$datasets"

[ "$mismatches" -eq 0 ] ||
  die "$mismatches dataset value(s) differ from this script's and were left alone.
       Change them by hand with 'zfs set', or change this script, then run it again."

# --- 3. Docker's log rotation ------------------------------------------------

if [ "$daemon_json_current" -eq 0 ]; then
  install -d -m 0755 /etc/docker
  install -m 0644 "$daemon_json" "$DAEMON_JSON"
  echo "  wrote $DAEMON_JSON; restarting Docker"
  systemctl restart docker.service
  docker info >/dev/null || die "Docker did not come back after the restart"
fi
rm -f "$daemon_json"

# --- 4. FilOne's paths, network, node.conf and units -------------------------

install -d -m 0700 /run/fil-one /run/fil-one/secrets /run/fil-one/bao
install -d -m 0755 /etc/fil-one /etc/tmpfiles.d
install_if_changed /etc/tmpfiles.d/filone.conf <<'TMPFILES' || true
d /run/fil-one 0700 root root -
d /run/fil-one/secrets 0700 root root -
d /run/fil-one/bao 0700 root root -
TMPFILES

if docker network inspect filone >/dev/null 2>&1; then
  actual_subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' filone)"
  [ "$actual_subnet" = "$FILONE_SUBNET" ] ||
    die "filone network uses $actual_subnet, expected $FILONE_SUBNET"
else
  docker network create --subnet "$FILONE_SUBNET" filone
fi

# filone_init reads this and then nodes/$NODE/node.env, which a later change
# adds; until then the deploy scripts stop at the missing node directory.
install_if_changed /etc/fil-one/node.conf <<CONF || true
FILONE_NODE=$NODE
FILONE_CHECKOUT=$CHECKOUT
FILONE_GIT_REF=main
CONF

FILONE_CHECKOUT="$CHECKOUT"
sync_systemd_units

date -u +%Y-%m-%dT%H:%M:%SZ | install_if_changed /etc/fil-one/bootstrap-complete || true

# The node.env of the later change commits this value, so it is printed rather
# than written: 80% of the blobs quota, leaving room above the budget for
# bodies in flight and under the 10%-free alert.
echo "prod/us-east-2 bootstrap complete"
echo "Set this in nodes/$NODE/node.env:"
echo "  INGOT_LOCAL_BLOB_MAX_BYTES=$((blobs_quota * 80 / 100))"
