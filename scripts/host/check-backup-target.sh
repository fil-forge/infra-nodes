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

BACKUP_PATH=backup-target

bao_has "$BACKUP_PATH" access_key_id ||
  die "OpenBao has no backup key at $FILONE_BAO_MOUNT/$BACKUP_PATH; run
       scripts/host/provision-backups.sh"
bao_has "$BACKUP_PATH" bucket ||
  die "$FILONE_BAO_MOUNT/$BACKUP_PATH holds the key pair but not the target it
       writes to, so it was stored before provision-backups.sh kept the target
       with it. Ask central to re-mint with MINT_ARGS=--reissue-backup-key, then
       run scripts/host/provision-backups.sh --replace."

bucket="$(bao_get "$BACKUP_PATH" bucket)"
key_prefix="$(bao_get "$BACKUP_PATH" key_prefix)"
aws_region="$(bao_get "$BACKUP_PATH" aws_region)"
access_key_id="$(bao_get "$BACKUP_PATH" access_key_id)"
secret_access_key="$(bao_get "$BACKUP_PATH" secret_access_key)"

[ "$key_prefix" = "$REGION_LABEL/" ] ||
  die "the stored backup key writes under $key_prefix, but this node is $REGION_LABEL
       and central's writer for it can write only under $REGION_LABEL/"
# The key pair goes into a curl config line between double quotes, where a quote
# or a backslash would change what curl reads. AWS keys contain neither.
[[ "$access_key_id" =~ ^[A-Z0-9]+$ ]] ||
  die "the stored access key ID is not in the form AWS issues"
[[ "$secret_access_key" =~ ^[A-Za-z0-9/+=]+$ ]] ||
  die "the stored secret access key is not in the form AWS issues"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
object_key="${key_prefix}provisioning-check/$timestamp"
url="https://$bucket.s3.$aws_region.amazonaws.com/$object_key"
body="provisioning check from $FILONE_NODE at $timestamp"

# S3 signs over the payload's SHA-256, and Object Lock refuses a put that
# carries no Content-MD5 or other checksum.
{
  read -r body_sha256
  read -r body_md5
} < <(printf '%s' "$body" | python3 -c '
import base64, hashlib, sys

b = sys.stdin.buffer.read()
print(hashlib.sha256(b).hexdigest())
print(base64.b64encode(hashlib.md5(b).digest()).decode())
')
[ -n "${body_sha256:-}" ] && [ -n "${body_md5:-}" ] ||
  die "could not hash the check object's body"

echo "  putting s3://$bucket/$object_key in $aws_region with access key $access_key_id"

# The key pair goes in on stdin as a curl config line. As a --user argument it
# would sit in curl's argv, where anything on the host that can read /proc can
# take it. printf is a shell builtin and never gets an argv of its own.
curl_status=0
response="$(printf 'user = "%s:%s"\n' "$access_key_id" "$secret_access_key" |
  curl -sS --max-time 30 --config - \
    --aws-sigv4 "aws:amz:$aws_region:s3" \
    --request PUT \
    --header "Content-Type: text/plain" \
    --header "Content-MD5: $body_md5" \
    --header "x-amz-content-sha256: $body_sha256" \
    --data-binary "$body" \
    --write-out '\n%{http_code}' \
    "$url")" || curl_status=$?
unset secret_access_key

[ "$curl_status" -eq 0 ] ||
  die "could not reach $url (curl $curl_status). The backup jobs upload over the
       same route, so fix this node's HTTPS egress to S3 in $aws_region."

status="$(printf '%s' "$response" | tail -1)"
s3_error="$(printf '%s' "$response" | sed '$d' |
  sed -n 's|.*<Code>\(.*\)</Code>.*<Message>\(.*\)</Message>.*|\1: \2|p')"

case "$status" in
  200)
    echo "  the backup key can write to its target" ;;
  403)
    case "$s3_error" in
      InvalidAccessKeyId*)
        die "S3 does not know access key $access_key_id: $s3_error
       Central deleted it, most likely by reissuing the backup key: claim the new
       one with scripts/host/provision-backups.sh --replace." ;;
      *)
        die "S3 refused the put (HTTP 403, ${s3_error:-no error code}).
       Central's writer for $REGION_LABEL cannot write s3://$bucket/$object_key.
       Check the writer's policy with scripts/check-appliance-backup-access.sh in
       infra-central." ;;
    esac ;;
  *)
    die "S3 answered HTTP $status (${s3_error:-no error code}) to the put to $url" ;;
esac
