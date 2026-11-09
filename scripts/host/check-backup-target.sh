#!/usr/bin/env bash
# Check that this node's backup key can write to its backup target.
#
# Reads the key pair and the target from filone/backup-target and puts a small
# object at <key_prefix>provisioning-check/<UTC timestamp> with that key, over
# the HTTPS endpoint the backup jobs use. A 200 means the key is live, the
# bucket and AWS region are right, the writer's policy allows the key prefix,
# and the put meets the bucket's TLS-only policy and Object Lock's demand for a
# checksum.
#
# The writer can neither read nor delete, so the object stays. Object Lock keeps
# it for 35 days and the bucket's lifecycle removes it a day later, as it does
# every backup.
#
# provision-backups.sh runs this after it stores the key, and on a node that
# already holds one. Run it by hand, as root, to check the key at any time.
#
# Usage:
#   scripts/host/check-backup-target.sh
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

node_takes_backups ||
  die "$FILONE_NODE_DIR/node.env sets FILONE_TAKES_BACKUPS=false, so this node has
       no backup target to check"
bao_is_unsealed || die "OpenBao is sealed; run provision-platform.sh first"

load_backup_target

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
object_key="${backup_key_prefix}provisioning-check/$timestamp"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
printf 'provisioning check from %s at %s' "$FILONE_NODE" "$timestamp" >"$body_file"

echo "  putting s3://$backup_bucket/$object_key in $backup_aws_region with access key $backup_access_key_id"

put_ok=true
s3_put_file "$body_file" "$object_key" text/plain || put_ok=false
unset backup_secret_access_key

if [ "$put_ok" = true ]; then
  echo "  the backup key can write to its target"
  exit 0
fi

case "$S3_PUT_STATUS" in
  403)
    case "$S3_PUT_ERROR" in
      InvalidAccessKeyId*)
        die "S3 does not know access key $backup_access_key_id: $S3_PUT_ERROR
       Central deleted it, most likely by reissuing the backup key: claim the new
       one with scripts/host/provision-backups.sh --replace." ;;
      *)
        die "S3 refused the put (HTTP 403, ${S3_PUT_ERROR:-no error code}).
       Central's writer for $REGION_LABEL cannot write s3://$backup_bucket/$object_key.
       Check the writer's policy with scripts/check-appliance-backup-access.sh in
       infra-central." ;;
    esac ;;
  *)
    die "S3 answered HTTP $S3_PUT_STATUS (${S3_PUT_ERROR:-no error code}) to the put to
       s3://$backup_bucket/$object_key" ;;
esac
