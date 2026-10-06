#!/usr/bin/env bash
# Pin one service on one node at one image digest.
#
# This is the only place that knows how a pin is written. The bump workflow, the
# refresh workflow and a person at a terminal all go through here, so a change
# to the file's shape lands in one place rather than three.
#
# Usage:
#   scripts/ci/set-node-pin.sh [--node <node>] <service> <sha256:...>
#
# Example:
#   scripts/ci/set-node-pin.sh piri "$(crane digest ghcr.io/fil-forge/piri:main)"
#   scripts/ci/set-node-pin.sh --node staging/eu-central-3 piri sha256:...
#
# Prints `changed=true` on stdout when the file was rewritten and
# `changed=false` when the service was already pinned there, and exits 0 either
# way. Everything a person reads goes to stderr, so a caller can append stdout
# straight to $GITHUB_OUTPUT. Anything else is an error: an unknown service, a
# malformed digest, a pin the pattern did not fit, or an edit that touched more
# than the one line.
#
# The node is a directory under nodes/, dev unless --node names another. The
# bump workflow pins dev; the staging promotion pins staging/eu-central-3.
#
# Prerequisites:
#   - a git work tree, because the one-line assertion reads `git diff`
#   - no credentials, and nothing outside versions.env is written
set -euo pipefail

USAGE="usage: scripts/ci/set-node-pin.sh [--node <node>] <service> <sha256:...>"
NODE=dev
case "${1-}" in
  -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --node)    NODE="${2-}"; shift 2 2>/dev/null || { echo "$USAGE" >&2; exit 2; } ;;
esac
case "${1-}" in
  "")        echo "$USAGE" >&2; exit 2 ;;
  -*)        echo "unknown option: $1" >&2; exit 2 ;;
esac

SERVICE="$1"
DIGEST="${2-}"
shift 2 2>/dev/null || { echo "$USAGE" >&2; exit 2; }
[ $# -eq 0 ] || { echo "ERROR: unexpected argument: $1" >&2; exit 2; }

# The variable each service is pinned through, and the image reference that
# variable carries. An unknown service would otherwise leave the file untouched
# and pass for "already pinned".
case "$SERVICE" in
  piri)  KEY=PIRI_IMAGE;  IMAGE=ghcr.io/fil-forge/piri:main ;;
  ingot) KEY=INGOT_IMAGE; IMAGE=ghcr.io/fil-forge/ingot:main ;;
  *) echo "ERROR: unknown service '$SERVICE'" >&2; exit 1 ;;
esac

[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "ERROR: malformed digest '$DIGEST', expected sha256:<64 hex>" >&2
  exit 1
}

# A node is a directory, so the name must not climb out of nodes/.
[[ "$NODE" =~ ^[a-z0-9-]+(/[a-z0-9-]+)?$ ]] || {
  echo "ERROR: malformed node '$NODE'" >&2
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="nodes/$NODE/apps/versions.env"
cd "$ROOT"
[ -f "$FILE" ] || { echo "ERROR: no $FILE for node '$NODE'" >&2; exit 1; }

# A pin carries the tag alongside the digest, and only the digest is rewritten.
# The tag is part of the pattern rather than part of the replacement, so a pin
# someone moved to another tag fails the assertion below instead of being
# silently rewritten back to :main.
PREFIX="${KEY}=${IMAGE}@"
pattern="$(sed 's/[.[\*^$/]/\\&/g' <<<"$PREFIX")"

sed -i.bak -E "s|^(${pattern})sha256:[0-9a-f]{64}\$|\1${DIGEST}|" "$FILE"
rm -f "$FILE.bak"

# Read the result rather than trusting sed. A pattern that matched nothing
# leaves the file untouched too, so a pin written differently than expected
# would otherwise pass for "already pinned".
if ! grep -qxF "${PREFIX}${DIGEST}" "$FILE"; then
  echo "ERROR: $FILE does not pin $SERVICE at $DIGEST" >&2
  git --no-pager diff -- "$FILE" >&2
  grep -nE "^${KEY}=" "$FILE" >&2 || true
  exit 1
fi

changes="$(git diff --numstat -- "$FILE")"
if [ -z "$changes" ]; then
  echo "$SERVICE is already pinned at $DIGEST" >&2
  echo "changed=false"
  exit 0
fi
if [ "$changes" != "$(printf '1\t1\t%s' "$FILE")" ]; then
  echo "ERROR: expected a one-line change" >&2
  git --no-pager diff -- "$FILE" >&2
  exit 1
fi

echo "pinned $SERVICE at $DIGEST" >&2
echo "changed=true"
