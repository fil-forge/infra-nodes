#!/usr/bin/env bash
# Mount every Piri volume an EC2 node has, at /mnt/fil-one/<piri>.
#
# The volumes are named in the instance's tags, one PiriVolume:<piri> tag per
# Piri holding its EBS volume id, read through the instance metadata service.
# Tags rather than user_data, because an edit to user_data replaces the
# instance and a tag edit does not: adding a Piri adds a volume, its
# attachment and a tag, then this script mounts it on the running node.
#
# Bootstrap runs it on first boot, and an operator runs it after adding a Piri
# (docs/RUNBOOK.md, "Add a Piri to a running node"). Safe to run again: a
# mounted volume is left alone, and a volume that already holds a filesystem is
# never formatted. Only for EC2 nodes; a bare-metal node mounts its disks
# itself.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

[ "$(id -u)" -eq 0 ] || die "must run as root"

IMDS=http://169.254.169.254/latest
# The longest lifetime IMDS grants: each volume may wait 300s to attach, so a
# shorter token could expire before the next volume's tag is read.
token="$(curl -sf --max-time 5 -X PUT "$IMDS/api/token" \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')" ||
  die "the instance metadata service did not answer; this script is for EC2 nodes"
imds() { curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $token" "$IMDS/meta-data/$1"; }

keys="$(imds tags/instance)" ||
  die "the instance exposes no tags; terraform sets metadata_options.instance_metadata_tags"
piris="$(grep -E '^PiriVolume:piri-[0-9]+$' <<<"$keys" | sed 's/^PiriVolume://' | sort -V || true)"
[ -n "$piris" ] || die "no PiriVolume:<piri> tag on this instance"

# The attachment is a separate API call made after the instance or the volume
# exists, so the device can appear a little after this starts. On Nitro the
# kernel names NVMe devices in attach order; the by-id link carries the volume
# id as the device serial, which is unambiguous.
wait_for_device() {
  local dev="$1" deadline=$(($(date +%s) + 300))
  until [ -e "$dev" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || die "$dev did not attach within 300s"
    sleep 5
  done
}

mount_piri_volume() {
  local piri="$1" volume_id="$2" mountpoint="$3" dev uuid
  dev="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volume_id//-/}"
  wait_for_device "$dev"

  # Format once, ever. A volume that already carries a filesystem holds a
  # Piri's stored data, and reformatting it is the one irreversible mistake
  # this script could make.
  if [ -z "$(blkid -o value -s TYPE "$dev" || true)" ]; then
    echo "  $piri: $dev is blank, creating ext4 labelled filone-$piri"
    mkfs.ext4 -q -L "filone-$piri" "$dev"
  fi

  mkdir -p "$mountpoint"
  uuid="$(blkid -o value -s UUID "$dev")"
  # By UUID, not by device path: the NVMe name changes with attach order.
  # nofail keeps a missing volume from dropping the box into emergency mode,
  # where SSM cannot reach it.
  grep -q "UUID=$uuid " /etc/fstab ||
    echo "UUID=$uuid $mountpoint ext4 defaults,nofail 0 2" >>/etc/fstab
  mount "$mountpoint"
  echo "  $piri: mounted $volume_id at $mountpoint"
}

for piri in $piris; do
  volume_id="$(imds "tags/instance/PiriVolume:$piri")" || die "could not read the $piri volume tag"
  [[ "$volume_id" =~ ^vol-[0-9a-f]+$ ]] || die "the $piri tag holds '$volume_id', not a volume id"
  mountpoint="/mnt/fil-one/$piri"

  if is_mounted "$mountpoint"; then
    echo "  $piri: mounted at $mountpoint"
  else
    mount_piri_volume "$piri" "$volume_id" "$mountpoint"
  fi

  # The Piri's data directory, one level below the mount point, as
  # provision-apps.sh creates it. Checked on every run, so a run that stopped
  # after mounting is finished by the next one. Only on a volume holding
  # nothing yet: a missing directory on a volume with data means that data
  # sits elsewhere.
  if [ -z "$(find "$mountpoint" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)" ]; then
    install -d -m 0755 "$mountpoint/$piri"
    echo "  $piri: created $mountpoint/$piri"
  fi
done
