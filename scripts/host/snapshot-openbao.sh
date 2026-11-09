#!/usr/bin/env bash
# Take a raft snapshot of this node's OpenBao and push it to the backup target.
#
# The snapshot goes up as OpenBao writes it. OpenBao encrypts every value before
# it reaches raft, and central's appliance-unseal-<region> key wraps the root
# key, so a snapshot cannot be read without the unseal key held at central.
# Storage paths (mount paths, policy names, secret names) stay in plaintext.
#
# Each snapshot goes to <key_prefix>openbao/<UTC timestamp>.snap under its own
# key. The node's backup key can put but not read or delete. The bucket keeps
# versions and locks each one in compliance mode, so a put to a key that already
# exists adds a version and leaves the earlier one in place. Central sets how
# long a snapshot is kept, as appliance_backups.retention_days in the stage's
# platform config: 35 days on staging, after which the bucket expires it.
#
# Runs from filone-openbao-snapshot.timer once a day, and from
# request_openbao_snapshot after anything writes to OpenBao. Run it by hand, as
# root, to take one now. It takes no deploy lock: deploys that hold the lock
# start it, and it reads OpenBao without changing the checkout or the node.
#
# Usage:
#   scripts/host/snapshot-openbao.sh
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

case "${1:-}" in
  "") ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0 ;;
  *) die "unknown option: $1" ;;
esac

filone_init

if ! node_takes_backups; then
  echo "  $FILONE_NODE_DIR/node.env sets FILONE_TAKES_BACKUPS=false; no snapshot taken"
  exit 0
fi

bao_is_unsealed || die "OpenBao is sealed, so there is nothing to snapshot.
       'docker logs $FILONE_BAO_CONTAINER' says why."

# Before anything is read, so a write that lands while this run is uploading
# leaves its marker in place for the next run.
started_at="$(date +%s)"
pending="$FILONE_STATE_DIR/openbao-snapshot-pending"

load_backup_target

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot_name="raft-$timestamp.snap"
# The socket directory is the one host path the container writes to that is a
# tmpfs, so the snapshot never touches a disk on this host.
host_file="$FILONE_BAO_SOCKET_DIR/$snapshot_name"
trap 'rm -f "$host_file"' EXIT

echo "=== OpenBao snapshot ($FILONE_NODE) ==="
bao operator raft snapshot save "/openbao/logs/$snapshot_name" >/dev/null ||
  die "OpenBao refused the snapshot. A host token minted before snapshots existed
       holds the filone-deploy policy, which does not allow it: run
       scripts/host/provision-host-token.sh with the root token from 1Password."
[ -s "$host_file" ] || die "OpenBao reported a snapshot, but $host_file is empty or missing"

object_key="${backup_key_prefix}openbao/$timestamp.snap"
echo "  uploading $(stat -c %s "$host_file") bytes to s3://$backup_bucket/$object_key"

put_ok=true
s3_put_file "$host_file" "$object_key" application/octet-stream || put_ok=false
unset backup_secret_access_key

if [ "$put_ok" != true ]; then
  case "$S3_PUT_ERROR" in
    InvalidAccessKeyId*)
      die "S3 does not know access key $backup_access_key_id: $S3_PUT_ERROR
       Central deleted it, most likely by reissuing the backup key: claim the new
       one with scripts/host/provision-backups.sh --replace." ;;
    *)
      die "S3 answered HTTP $S3_PUT_STATUS (${S3_PUT_ERROR:-no error code}) to the put to
       s3://$backup_bucket/$object_key. scripts/host/check-backup-target.sh tests
       the key and the target on their own." ;;
  esac
fi

# Only a marker older than this run is covered by the snapshot just uploaded.
if [ -e "$pending" ] && [ "$(stat -c %Y "$pending")" -lt "$started_at" ]; then
  rm -f "$pending"
fi

stamp_openbao_snapshot_success
echo "=== snapshot uploaded ==="
