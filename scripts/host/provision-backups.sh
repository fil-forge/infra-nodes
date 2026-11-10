#!/usr/bin/env bash
# Store the access key this node writes its Postgres and OpenBao backups with,
# and where it writes them, then check that the key can write there.
#
# Central mints the key and hands back a single-use wrapping token, as it does
# for the seal token. This script asks for that token, exchanges it at the
# central OpenBao, and stores what comes back in this node's own OpenBao at
# filone/backup-target: the key pair (access_key_id, secret_access_key) and the
# target central minted it for (bucket, key_prefix, aws_region). The backup jobs
# read all five from there, so the key and the target cannot disagree, and the
# key exists on disk only under the node's seal.
#
# It then runs check-backup-target.sh, which writes a small object with the
# stored key, so a key that cannot write fails here rather than at the first
# backup. Once that write succeeds it uploads the first OpenBao snapshot with
# snapshot-openbao.sh and enables filone-openbao-snapshot.timer, which takes
# one daily from then on.
#
# provision-platform.sh runs this on a new node. Run it by hand, as root in an
# SSM session or on the host, to add the key to a node provisioned before it
# existed, or with --replace after central reissued the key.
#
# Does nothing on a node whose node.env sets FILONE_TAKES_BACKUPS=false. On a
# node that already holds a key it stores nothing unless --replace is given, and
# checks the key it holds.
#
# Usage:
#   scripts/host/provision-backups.sh [--replace]
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

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
  echo "  $FILONE_NODE_DIR/node.env sets FILONE_TAKES_BACKUPS=false,"
  echo "  so this node takes no backups and needs no backup key"
  exit 0
fi

bao_is_unsealed || die "OpenBao is sealed; run provision-platform.sh first"

BACKUP_PATH="$FILONE_BACKUP_PATH"

# Once the stored key has written to the target, and not before: a timer
# enabled on a node whose key cannot write would fail every day until the
# stale-snapshot alert noticed. The first snapshot runs here, in the
# foreground, so a host token that cannot take one stops this script at the
# prompt, and the alert has a value to watch from the start.
check_and_start_snapshots() {
  "$SCRIPT_DIR/check-backup-target.sh"
  "$SCRIPT_DIR/snapshot-openbao.sh"
  # The timer may not be on the box yet: this can run before the first
  # reconcile pass has installed the checkout's units.
  sync_systemd_units
  systemctl enable --now "$FILONE_SNAPSHOT_TIMER" >/dev/null ||
    die "could not enable $FILONE_SNAPSHOT_TIMER"
  echo "  $FILONE_SNAPSHOT_TIMER enabled"
}

if bao_has "$BACKUP_PATH" access_key_id && [ "$REPLACE" != true ]; then
  echo "  backup key already stored: access key $(bao_get "$BACKUP_PATH" access_key_id)"
  echo "  run with --replace after central reissues it"
  check_and_start_snapshots
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

# Central wraps five fields: the key pair and the target it may write to. All
# five are stored, NUL separated as name/value pairs for the KV write,
# access_key_id first because it is the field bao_put_if_absent looks up.
#
# The key prefix has to be this node's region: central's writer for a region
# can write only under that region's key prefix, so a key minted for another
# region is a token delivered to the wrong node. The bucket and AWS region end
# up in the upload URL, so they are held to the forms S3 accepts.
fields=()
while IFS= read -r -d '' item; do
  fields+=("$item")
done < <(printf '%s' "$body" | python3 -c '
import json, os, re, sys

data = json.load(sys.stdin).get("data") or {}
names = ["access_key_id", "secret_access_key", "bucket", "key_prefix", "aws_region"]
missing = [n for n in names if not isinstance(data.get(n), str) or not data[n]]
if missing:
    sys.exit("the unwrapped response lacks " + ", ".join(missing))

region_label = os.environ["REGION_LABEL"]
if data["key_prefix"] != region_label + "/":
    sys.exit("central minted the key for key prefix " + data["key_prefix"] + ", but this node is "
             + region_label + " and writes only under " + region_label + "/")
if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", data["bucket"]):
    sys.exit("central sent a bucket name S3 does not accept: " + data["bucket"])
if not re.fullmatch(r"[a-z]{2}(-[a-z]+)+-[0-9]", data["aws_region"]):
    sys.exit("central sent an AWS region that is not one: " + data["aws_region"])

for n in names:
    sys.stdout.write(n + "\0" + data[n] + "\0")
')
unset body item
[ "${#fields[@]}" -eq 10 ] ||
  die "nothing was stored, for the reason above. The wrapping token is spent and
       the key it carried is live in IAM, so ask central to re-mint the region it
       was minted for with MINT_ARGS=--reissue-backup-key, which deletes it."

if [ "$REPLACE" = true ]; then
  bao_replace_fields "$BACKUP_PATH" "${fields[@]}"
else
  bao_put_if_absent "$BACKUP_PATH" "${fields[@]}"
fi
unset fields

echo "  stored access key $(bao_get "$BACKUP_PATH" access_key_id) for" \
  "s3://$(bao_get "$BACKUP_PATH" bucket)/$(bao_get "$BACKUP_PATH" key_prefix)" \
  "in $(bao_get "$BACKUP_PATH" aws_region)"

check_and_start_snapshots
