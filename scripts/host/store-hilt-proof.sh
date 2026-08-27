#!/usr/bin/env bash
# Store hilt's delegation to this node's Ingot, the one piece of onboarding only
# Forge Central can produce.
#
# Central signs it during `make onboard-appliance` and hands it back to the node
# operator. Without it deploy-apps.sh refuses to start Ingot, because an Ingot
# with no proof gets a 401 on every /s3/* invocation it makes and says nothing
# useful about why.
#
# Usage:
#   scripts/host/store-hilt-proof.sh <file>   (- for stdin)
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SOURCE="${1:?usage: store-hilt-proof.sh <file>   (- for stdin)}"

filone_init

bao_is_unsealed || die "OpenBao is sealed; run provision-platform.sh first"

if [ "$SOURCE" = "-" ]; then
  # Reading a pasted blob looks like a hang otherwise: no prompt, and nothing
  # happens until the stream closes.
  if [ -t 0 ]; then
    echo "Paste the delegation, press Enter, then Ctrl-D to close the input." >&2
  fi
  proof="$(cat)"
else
  [ -r "$SOURCE" ] || die "cannot read $SOURCE"
  proof="$(cat "$SOURCE")"
fi

# A delegation is a single base64 token. Anything with whitespace in it is a
# transcription accident, and OpenBao would store it without complaint.
proof="$(printf '%s' "$proof" | tr -d '[:space:]')"
[ -n "$proof" ] || die "$SOURCE holds no delegation"

echo "=== store hilt proof ($FILONE_NODE) ==="
echo "  Ingot: $(bao_get ingot did)"

# patch, so the Ingot's own key and DID at this path survive. The value goes in
# over stdin: on the command line it would be in the container's argv.
bao kv patch -mount="$FILONE_BAO_MOUNT" ingot hilt_proof=- <<<"$proof" >/dev/null ||
  die "could not write $FILONE_BAO_MOUNT/ingot#hilt_proof"

echo "  stored. Next: scripts/host/provision-apps.sh"
