#!/usr/bin/env bash
# Check that an OpenBao snapshot restores, unseals and holds this node's
# identities, without touching the node's own OpenBao.
#
# Restores the snapshot into a throwaway OpenBao container, filone-openbao-verify,
# started from the node's pinned image with the node's own bao.hcl and seal
# token. The container's storage is a scratch directory on the /run tmpfs and it
# publishes no ports. It unseals through central exactly as the node's OpenBao
# would after a restore, so a snapshot that passes here restores on the node.
#
# Then asks for the root token from 1Password that was valid when the snapshot
# was taken, and compares each Piri's and Ingot's DID in the snapshot with the one
# the node's OpenBao holds. Exits non-zero when an identity differs or is
# missing from the snapshot, because a restore from it would lose that identity.
#
# Runs while the node keeps serving: it never stops a container, touches the
# live store or the timers, or uploads anything. The throwaway container, its
# scratch directory and the copy of the seal token are removed on exit, whether
# the check passed, failed or was interrupted. The snapshot file is left for the
# operator to delete.
#
# Usage:
#   scripts/host/verify-openbao-snapshot.sh <snapshot file>
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

case "${1:-}" in
  "") die "usage: verify-openbao-snapshot.sh <snapshot file>" ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0 ;;
esac
SNAPSHOT="$1"

filone_init
unset BAO_TOKEN

[ -s "$SNAPSHOT" ] || die "$SNAPSHOT is missing or empty"
[ -r "$FILONE_SEAL_TOKEN_FILE" ] || die "no seal token at $FILONE_SEAL_TOKEN_FILE"
bao_is_unsealed || die "the node's OpenBao is sealed, and this check compares the snapshot against it"

VERIFY_CONTAINER=filone-openbao-verify
image="$(sed -n 's/^OPENBAO_IMAGE=//p' "$FILONE_NODE_DIR/platform/versions.env")"
[ -n "$image" ] || die "no OPENBAO_IMAGE in $FILONE_NODE_DIR/platform/versions.env"

if container_exists "$VERIFY_CONTAINER"; then
  die "$VERIFY_CONTAINER already exists. Another check is running, or one was killed
       before it could clean up; 'docker rm -f $VERIFY_CONTAINER' removes it."
fi

# Not under $FILONE_BAO_SOCKET_DIR: the throwaway server puts its unix listener
# at /openbao/logs/api.sock, and that directory holds the node's own.
scratch="$(mktemp -d /run/fil-one/openbao-verify.XXXXXX)"
trap cleanup EXIT
trap 'exit 130' INT TERM
cleanup() {
  docker rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}

mkdir "$scratch/file" "$scratch/logs"
cp "$SNAPSHOT" "$scratch/logs/verify.snap"

# Through an env file rather than `-e`, which would put the seal token in
# docker's argv.
install -m 0400 /dev/null "$scratch/seal.env"
printf 'VAULT_TRANSIT_SEAL_TOKEN=%s\n' "$(cat "$FILONE_SEAL_TOKEN_FILE")" >"$scratch/seal.env"

echo "=== verify OpenBao snapshot ($FILONE_NODE) ==="
echo "[1/3] Starting $VERIFY_CONTAINER from $image"
# The same bao.hcl as the node's OpenBao. Its raft node_id has to match the one
# recorded in the snapshot, and its seal stanza names the transit key that
# unwraps the snapshot's root key. Run as root, as compose.yml runs the node's.
docker run -d --name "$VERIFY_CONTAINER" \
  --user 0:0 \
  --env-file "$scratch/seal.env" \
  --volume "$FILONE_NODE_DIR/platform/config/openbao/bao.hcl:/etc/openbao/bao.hcl:ro" \
  --volume "$scratch/file:/openbao/file" \
  --volume "$scratch/logs:/openbao/logs" \
  --memory 512m --cpus 1 \
  "$image" server -config=/etc/openbao/bao.hcl >/dev/null ||
  die "could not start $VERIFY_CONTAINER"
wait_for_bao "$VERIFY_CONTAINER"
! bao_is_initialised "$VERIFY_CONTAINER" ||
  die "$VERIFY_CONTAINER came up initialised on an empty scratch directory"

echo "[2/3] Restoring $SNAPSHOT"
restore_bao_snapshot "$VERIFY_CONTAINER" verify.snap
echo "  restored and unsealed"

echo "[3/3] Comparing identities with the node's OpenBao"
echo "  paste the root token from 1Password (not echoed):"
read -rsp "root token: " root_token
echo
[ -n "$root_token" ] || die "no root token given"
token_status=0
bao_rejects_token "$VERIFY_CONTAINER" "$root_token" || token_status=$?
case "$token_status" in
  1) ;;
  0) die "the restored store rejects that root token. It takes the root token that
       was valid when the snapshot was taken. A snapshot older than a rotation of
       the root token takes the earlier one, which 1Password keeps in an item of
       its own; docs/runbook/rotate-openbao-root-token.md says which." ;;
  *) die "could not ask the restored store about the root token; 'docker logs $VERIFY_CONTAINER'
       may say why, until this script exits and removes it." ;;
esac

mismatches=0
missing=0
for name in $(piri_services) ingot; do
  if ! bao_has "$name" did; then
    echo "  $name: the node's OpenBao holds no DID for it; skipped"
    continue
  fi
  live_did="$(bao_get "$name" did)"

  if ! snapshot_did="$(BAO_TOKEN="$root_token" bao_in "$VERIFY_CONTAINER" \
    kv get -mount="$FILONE_BAO_MOUNT" -field=did "$name" 2>/dev/null)"; then
    echo "  $name: MISSING from the snapshot. A restore would lose this identity."
    missing=$((missing + 1))
    continue
  fi

  if [ "$snapshot_did" = "$live_did" ]; then
    echo "  $name: $live_did"
  else
    echo "  $name: MISMATCH. The node holds $live_did, the snapshot $snapshot_did"
    mismatches=$((mismatches + 1))
  fi
done
unset root_token

[ "$mismatches" -eq 0 ] ||
  die "$mismatches identities in the snapshot differ from the node's"
[ "$missing" -eq 0 ] ||
  die "the snapshot restores and unseals, but lacks $missing of the node's identities"
echo "=== the snapshot restores, unseals and holds the node's identities ==="
