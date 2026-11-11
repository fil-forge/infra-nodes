#!/usr/bin/env bash
# Put a staging or dev node into the state a lost OpenBao store leaves it in,
# for a restore drill. Moves things aside and deletes nothing, and prints the
# commands that put them back.
#
# Without options it simulates a failed control storage on a node that comes
# back within hours: the raft directory is moved aside and an empty one takes
# its place, while the seal token and the host token on the root disk stay
# where they are.
#
# With --lose-root-disk-tokens it simulates an outage of 72 hours or more, or a
# rebuilt host: both tokens are moved aside too. The restore then needs a seal
# token reissued by central, and provision-platform.sh mints a new host token.
#
# Everything moved goes into $FILONE_CONTROL_DIR/openbao-drill-<UTC timestamp>/,
# together with rollback.sh, which puts the original store back. A copy of the
# host token goes there in either mode, because the restore can replace it and a
# rollback to the original store needs the one that store issued.
# openbao-restore-cleanup.sh deletes these directories once the drill is over.
#
# Disables the reconcile, snapshot and seal-token-renew timers and stops the
# apps and OpenBao. Asks the operator to type the node's name before it changes
# anything.
#
# Usage:
#   scripts/host/simulate-openbao-loss.sh [--lose-root-disk-tokens]
set -euo pipefail

script_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"

LOSE_TOKENS=false
while [ $# -gt 0 ]; do
  case "$1" in
    --lose-root-disk-tokens) LOSE_TOKENS=true; shift ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

filone_init

case "$STAGE" in
  staging | dev) ;;
  *) die "this node's stage is $STAGE. Restore drills run on staging and dev only." ;;
esac

raft_dir="$FILONE_CONTROL_DIR/openbao"
if [ ! -d "$raft_dir" ] || ! find "$raft_dir" -mindepth 1 -print -quit | grep -q .; then
  die "$raft_dir is empty or missing, so there is no store to lose"
fi

if [ "$LOSE_TOKENS" = true ]; then
  scenario="an outage of 72 hours or more: the raft directory, the seal token and the host token"
else
  scenario="a failed control storage: the raft directory alone"
fi
echo "This takes $FILONE_NODE out of service and simulates $scenario."
read -rp "Type the node name to continue: " answer
[ "$answer" = "$FILONE_NODE" ] || die "'$answer' is not $FILONE_NODE; nothing was changed"

# Write a script that puts back what this run moves aside. Every path is fixed
# now, so it runs from any directory and in any later shell.
write_rollback_script() {
  local file="$1"
  cat >"$file" <<EOF
#!/usr/bin/env bash
# Roll $FILONE_NODE back to the OpenBao store simulate-openbao-loss.sh moved
# aside into $drill_dir.
#
# The seal token goes back only when there is none on disk: once central has
# reissued it, the one moved aside is revoked, and the reissued one unseals
# this store as well.
set -euo pipefail

if [ ! -d $drill_dir/openbao ] || [ -e $drill_dir/openbao.restored ]; then
  echo "ERROR: $drill_dir no longer holds the original store; was it rolled back already?" >&2
  exit 1
fi

docker stop $FILONE_BAO_CONTAINER >/dev/null
mv -T $raft_dir $drill_dir/openbao.restored
mv -T $drill_dir/openbao $raft_dir
[ ! -e $drill_dir/bao-token ] || mv -f $drill_dir/bao-token $FILONE_BAO_TOKEN_FILE
[ -e $FILONE_SEAL_TOKEN_FILE ] || mv $drill_dir/seal-token $FILONE_SEAL_TOKEN_FILE
$script_dir/deploy-platform.sh
$script_dir/deploy-apps.sh
systemctl enable --now filone-reconcile.timer $FILONE_SNAPSHOT_TIMER filone-seal-token-renew.timer
echo "$FILONE_NODE runs on its original OpenBao store again."
EOF
  chmod 0700 "$file"
}

drill_dir="$FILONE_CONTROL_DIR/openbao-drill-$(date -u +%Y%m%dT%H%M%SZ)"

echo "=== simulate OpenBao loss ($FILONE_NODE) ==="

echo "[1/3] Pausing the timers"
pause_node_timers
[ -n "$PAUSED_TIMERS" ] || echo "  none was enabled"

echo "[2/3] Stopping the apps and OpenBao"
stop_apps || echo "  no app container was running"
if container_running "$FILONE_BAO_CONTAINER"; then
  echo "  stopping $FILONE_BAO_CONTAINER"
  docker stop "$FILONE_BAO_CONTAINER" >/dev/null || die "could not stop $FILONE_BAO_CONTAINER"
fi

echo "[3/3] Moving the store aside to $drill_dir"
install -d -m 0700 "$drill_dir"
move_bao_store_aside "$drill_dir/openbao"
echo "  $raft_dir is now empty"

if [ "$LOSE_TOKENS" = true ]; then
  mv "$FILONE_SEAL_TOKEN_FILE" "$drill_dir/seal-token"
  echo "  moved $FILONE_SEAL_TOKEN_FILE aside"
  if [ -e "$FILONE_BAO_TOKEN_FILE" ]; then
    mv "$FILONE_BAO_TOKEN_FILE" "$drill_dir/bao-token"
    echo "  moved $FILONE_BAO_TOKEN_FILE aside"
  fi
elif [ -e "$FILONE_BAO_TOKEN_FILE" ]; then
  cp -p "$FILONE_BAO_TOKEN_FILE" "$drill_dir/bao-token"
fi

rollback="$drill_dir/rollback.sh"
write_rollback_script "$rollback"

cat <<EOF

=== $FILONE_NODE has lost its OpenBao store ===
Next: the restore, as docs/runbook/restore-openbao-from-snapshot.md describes.

To roll back to the original store instead, at any point, run:

  $rollback
EOF
