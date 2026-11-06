#!/usr/bin/env bash
# Store the access key this node writes its Postgres and OpenBao backups with.
#
# Central mints the key and hands back a single-use wrapping token, as it does
# for the seal token. This script asks for that token, exchanges it at the
# central OpenBao, and stores the access key pair in this node's own OpenBao at
# filone/backup-target, so the key exists on disk only under the node's seal.
# The backup jobs read it from there, and read where to write from node.env:
# BACKUP_S3_BUCKET, BACKUP_S3_PREFIX and BACKUP_S3_REGION. Central wraps the
# same three values with the key, and a key minted for another target is
# refused rather than stored.
#
# provision-platform.sh runs this on a new node. Run it by hand, as root in an
# SSM session or on the host, to add the key to a node provisioned before it
# existed, or with --replace after central reissued the key.
#
# Does nothing on a node whose node.env names no backup target, and skips a node
# that already holds a key unless --replace is given.
#
# Usage:
#   scripts/host/provision-backups.sh [--replace]
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

REPLACE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --replace) REPLACE=true; shift ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

filone_init

if ! node_takes_backups; then
  echo "  $FILONE_NODE_DIR/node.env names no backup target,"
  echo "  so this node takes no backups and needs no backup key"
  exit 0
fi
TARGET="s3://$BACKUP_S3_BUCKET/$BACKUP_S3_PREFIX in $BACKUP_S3_REGION"

bao_is_unsealed || die "OpenBao is sealed; run provision-platform.sh first"

BACKUP_PATH=backup-target

if bao_has "$BACKUP_PATH" access_key_id && [ "$REPLACE" != true ]; then
  echo "  backup key already stored: access key $(bao_get "$BACKUP_PATH" access_key_id)," \
    "for $TARGET"
  echo "  run with --replace after central reissues it"
  exit 0
fi

echo "  Central runs 'make mint-appliance-credentials' in infra-central and hands back a"
echo "  wrapping token for the backup key. Paste it here; it is not echoed."
echo "  Exchanging it spends it, and what comes back is stored in this node's OpenBao."
read -rsp "backup-key wrapping token: " wrapping_token
echo
[ -n "$wrapping_token" ] || die "no wrapping token given"

# On success this holds the secret access key, so it is never printed.
body="$(unwrap_at_central "$wrapping_token" --reissue-backup-key)" || exit 1
unset wrapping_token

# Central wraps five fields: the key pair and the target it may write to. The
# target has to match node.env, which is what the backup jobs write to; a key
# minted for another bucket or region would fail every upload with an
# AccessDenied that says nothing about why. Only the key pair is stored, NUL
# separated as name/value pairs for the KV write, access_key_id first because it
# is the field bao_put_if_absent looks up.
fields=()
while IFS= read -r -d '' item; do
  fields+=("$item")
done < <(printf '%s' "$body" | python3 -c '
import json, os, sys

data = json.load(sys.stdin).get("data") or {}
names = ["access_key_id", "secret_access_key", "bucket", "prefix", "aws_region"]
missing = [n for n in names if not isinstance(data.get(n), str) or not data[n]]
if missing:
    sys.exit("the unwrapped response lacks " + ", ".join(missing))
for field, env in [("bucket", "BACKUP_S3_BUCKET"), ("prefix", "BACKUP_S3_PREFIX"), ("aws_region", "BACKUP_S3_REGION")]:
    if data[field] != os.environ[env]:
        sys.exit("central minted the key for " + field + " " + data[field]
                 + " but node.env sets " + env + "=" + os.environ[env])
for n in ["access_key_id", "secret_access_key"]:
    sys.stdout.write(n + "\0" + data[n] + "\0")
')
unset body item
[ "${#fields[@]}" -eq 4 ] ||
  die "nothing was stored. The wrapping token is spent and the key it carried is
       live in IAM, so fix whichever of node.env and central is wrong, then ask
       central to re-mint with MINT_ARGS=--reissue-backup-key, which deletes it."

if [ "$REPLACE" = true ]; then
  bao_replace_fields "$BACKUP_PATH" "${fields[@]}"
else
  bao_put_if_absent "$BACKUP_PATH" "${fields[@]}"
fi
unset fields

echo "  stored access key $(bao_get "$BACKUP_PATH" access_key_id) for $TARGET"
