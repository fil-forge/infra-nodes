#!/usr/bin/env bash
# Delete what an OpenBao restore or a restore drill left on this node, once it
# runs on a restored store again:
#
# - the openbao.damaged-* directories the damaged store was moved to before a
#   restore;
# - the openbao-drill-* directories simulate-openbao-loss.sh created;
# - the seal-token.expired-* and bao-token.rejected-* files moved aside during a
#   restore.
#
# A damaged or drill directory may hold the only copy of a store, and a drill
# directory also holds the rollback.sh that puts that store back. The script
# therefore refuses unless OpenBao runs unsealed on a raft directory that is not
# empty, lists what it will delete, and asks the operator to type the node's
# name first.
#
# A drill's marker object sits in a staging bucket, not on the node, and is
# deleted from the laptop as docs/runbook/restore-openbao-from-snapshot.md
# describes.
#
# Usage:
#   scripts/host/openbao-restore-cleanup.sh
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

raft_dir="$FILONE_CONTROL_DIR/openbao"
if [ ! -d "$raft_dir" ] || ! find "$raft_dir" -mindepth 1 -print -quit | grep -q .; then
  die "$raft_dir is empty or missing, so a directory this script deletes may hold the only copy of the store. Finish the restore, or run the drill's rollback.sh, first."
fi
bao_is_unsealed ||
  die "$FILONE_BAO_CONTAINER is not running unsealed, so a directory this script deletes may hold the only working store. Finish the restore, or run the drill's rollback.sh, first."

leftovers=()
while IFS= read -r path; do
  leftovers+=("$path")
done < <(
  find "$FILONE_CONTROL_DIR" -mindepth 1 -maxdepth 1 -type d \
    \( -name 'openbao.damaged-*' -o -name 'openbao-drill-*' \)
  find "$(dirname "$FILONE_SEAL_TOKEN_FILE")" -mindepth 1 -maxdepth 1 \
    -name "$(basename "$FILONE_SEAL_TOKEN_FILE").expired-*"
  find "$(dirname "$FILONE_BAO_TOKEN_FILE")" -mindepth 1 -maxdepth 1 \
    -name "$(basename "$FILONE_BAO_TOKEN_FILE").rejected-*"
)

if [ "${#leftovers[@]}" -eq 0 ]; then
  echo "No restore leftovers on $FILONE_NODE."
  exit 0
fi

echo "This deletes, on $FILONE_NODE:"
printf '  %s\n' "${leftovers[@]}"
read -rp "Type the node name to continue: " answer
[ "$answer" = "$FILONE_NODE" ] || die "'$answer' is not $FILONE_NODE; nothing was deleted"

for path in "${leftovers[@]}"; do
  rm -rf -- "$path"
  echo "  deleted $path"
done
