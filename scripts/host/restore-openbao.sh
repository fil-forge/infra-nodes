#!/usr/bin/env bash
# Restore this node's OpenBao from a raft snapshot, into an empty raft
# directory.
#
# For a node whose OpenBao store is lost: the control storage failed, the raft
# directory is corrupt, or the host was rebuilt. Restores the store and nothing
# else. provision-platform.sh, run next, brings back what lives outside it: the
# host token, a snapshot of the restored store, Ingot's region-key token, and
# the platform.
#
# The snapshot file has to be in /run/fil-one/bao, the tmpfs mounted into the
# OpenBao container as /openbao/logs, so it never lands on a disk on this host.
# It is deleted once the restore succeeds. The raft directory has to be empty or
# missing, unless --move-aside-damaged-store is given: the store in it then moves
# to openbao.damaged-<UTC timestamp> next to it, once OpenBao has stopped.
# openbao-restore-cleanup.sh deletes it once the node checks out. Nothing here
# deletes a store.
#
# What it does, in order:
#   1. Disables the reconcile, snapshot and seal-token-renew timers. It never
#      re-enables them, so a half-restored node takes no snapshot and no deploy.
#   2. Stops the apps and the OpenBao container, and moves the damaged store
#      aside when asked to.
#   3. Claims a seal token from central when none is on disk. This one prompt
#      is the only one, and it comes only after an outage of 72 hours or more,
#      or on a rebuilt host.
#   4. Starts OpenBao on the empty directory, initialises a throwaway store,
#      restores the snapshot over it and waits until the snapshot's store is
#      unsealed. The throwaway store's credentials are never printed.
#   5. Moves aside a host token the restored store rejects, so
#      provision-platform.sh mints a new one.
#
# Uploads nothing: the first snapshot of the restored store is the one
# provision-platform.sh takes, once the host token works again.
#
# Usage:
#   scripts/host/restore-openbao.sh [--move-aside-damaged-store] /run/fil-one/bao/<snapshot file>
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

MOVE_ASIDE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --move-aside-damaged-store) MOVE_ASIDE=true; shift ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] ||
  die "usage: restore-openbao.sh [--move-aside-damaged-store] /run/fil-one/bao/<snapshot file>"

filone_init
# bao() prefers BAO_TOKEN over the host token file, and step 5 asks whether the
# file's token works.
unset BAO_TOKEN

snapshot="$(realpath -e "$1" 2>/dev/null)" || die "$1 does not exist"
[ "$(dirname "$snapshot")" = "$FILONE_BAO_SOCKET_DIR" ] ||
  die "$snapshot is not in $FILONE_BAO_SOCKET_DIR. Stream the snapshot there: it is
       the tmpfs mounted into the OpenBao container, so the file stays off this
       host's disks and OpenBao can read it."
[ -s "$snapshot" ] || die "$snapshot is empty"
snapshot_name="$(basename "$snapshot")"

raft_dir="$FILONE_CONTROL_DIR/openbao"
damaged_store=false
if [ -d "$raft_dir" ] && find "$raft_dir" -mindepth 1 -print -quit | grep -q .; then
  damaged_store=true
  if [ "$MOVE_ASIDE" != true ]; then
    ls -la "$raft_dir" >&2
    die "$raft_dir holds a store already. If it is the damaged one this restore
       replaces, run again with --move-aside-damaged-store."
  fi
fi

echo "=== restore OpenBao ($FILONE_NODE) ==="

echo "[1/5] Pausing the timers"
pause_node_timers
[ -n "$PAUSED_TIMERS" ] || echo "  none was enabled"

echo "[2/5] Stopping the apps and OpenBao"
stop_apps || echo "  no app container was running"
if container_running "$FILONE_BAO_CONTAINER"; then
  echo "  stopping $FILONE_BAO_CONTAINER"
  docker stop "$FILONE_BAO_CONTAINER" >/dev/null || die "could not stop $FILONE_BAO_CONTAINER"
fi
if [ "$damaged_store" = true ]; then
  damaged_dir="$raft_dir.damaged-$(date -u +%Y%m%dT%H%M%SZ)"
  move_bao_store_aside "$damaged_dir"
  echo "  moved the damaged store to $damaged_dir"
fi
[ -d "$raft_dir" ] || install -d -m 0700 "$raft_dir"

if [ ! -r "$FILONE_SEAL_TOKEN_FILE" ]; then
  echo "[3/5] Claiming a seal token from $(central_seal_addr)"
  echo
  echo "  Central runs 'make mint-appliance-credentials' in infra-central with"
  echo "  MINT_ARGS=--reissue-unseal-token and hands back a wrapping token. Paste it"
  echo "  here; it is not echoed. Exchanging it spends it, and what comes back is"
  echo "  stored 0400 root."
  claim_seal_token
else
  echo "[3/5] Seal token already present"
fi

echo "[4/5] Restoring $snapshot_name"
start_openbao
! bao_is_initialised ||
  die "$FILONE_BAO_CONTAINER reports an initialised store on the empty $raft_dir"

# From the init inside restore_bao_snapshot until the snapshot's store answers,
# the raft directory holds either a throwaway store whose root token nobody has
# or a restored store that has not unsealed. Neither is worth keeping, and a
# re-run refuses a directory that is not empty, so a failure in between empties
# it again. It was empty when this run started.
restoring=true
trap 'on_exit $?' EXIT
on_exit() {
  [ "$1" -ne 0 ] && [ "$restoring" = true ] || return 0
  docker stop "$FILONE_BAO_CONTAINER" >/dev/null 2>&1 || true
  find "$raft_dir" -mindepth 1 -delete
  echo "  emptied $raft_dir again, so a re-run starts from the same state" >&2
}

restore_bao_snapshot "$FILONE_BAO_CONTAINER" "$snapshot_name"
restoring=false
rm -f "$snapshot"
echo "  restored and unsealed; $snapshot_name deleted"

echo "[5/5] Checking the host token"
if [ ! -r "$FILONE_BAO_TOKEN_FILE" ]; then
  echo "  no host token on disk; provision-platform.sh mints one"
else
  token_status=0
  bao_rejects_token "$FILONE_BAO_CONTAINER" "$(cat "$FILONE_BAO_TOKEN_FILE")" || token_status=$?
  case "$token_status" in
    0)
      # Rejected because it lapsed during the outage, or because a store newer
      # than the snapshot minted it.
      rejected="$FILONE_BAO_TOKEN_FILE.rejected-$(date -u +%Y%m%dT%H%M%SZ)"
      mv "$FILONE_BAO_TOKEN_FILE" "$rejected"
      echo "  the restored store rejects the host token on disk; moved it to $rejected,"
      echo "  and provision-platform.sh mints a new one" ;;
    1) echo "  the restored store accepts the host token on disk" ;;
    *)
      die "could not ask the restored store about the host token on disk. The store
       is restored and unsealed; check 'docker logs $FILONE_BAO_CONTAINER', then
       run provision-platform.sh. If the token turns out to be rejected, move
       $FILONE_BAO_TOKEN_FILE aside first so it mints a new one." ;;
  esac
fi

echo
echo "=== OpenBao restored ==="
echo "Next: provision-platform.sh. It asks for the root token from 1Password, and"
echo "enables the snapshot timer. filone-reconcile.timer and"
echo "filone-seal-token-renew.timer stay disabled until the node checks out."
