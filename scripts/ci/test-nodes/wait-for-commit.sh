#!/usr/bin/env bash
# Wait until a node reports that it has reached a commit, or a descendant of it.
#
# A merge queues a change rather than deploying it: the node picks it up on its
# next reconcile pass and can spend 45 minutes in the proving gate before Piri
# restarts. This polls the node's status document once a minute and gives up
# after 60 minutes.
#
# Usage:
#   scripts/ci/test-nodes/wait-for-commit.sh <node> <commit>
#
# Example:
#   scripts/ci/test-nodes/wait-for-commit.sh dev "$(git rev-parse HEAD)"
#
# The document is served at /.well-known/filone-node-status.json under the
# node's Piri hostname, read from nodes/<node>/node.env.
#
# Prerequisites:
#   - curl, jq, and a git work tree holding both the commit and the one the node
#     reports, which can be several commits ahead
set -euo pipefail

usage="usage: scripts/ci/test-nodes/wait-for-commit.sh <node> <commit>"
[ $# -eq 2 ] || { echo "$usage" >&2; exit 2; }
NODE="$1"
COMMIT="$2"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

env_file="nodes/$NODE/node.env"
[ -f "$env_file" ] || { echo "::error::no $env_file"; exit 1; }
git cat-file -e "$COMMIT^{commit}" 2>/dev/null ||
  { echo "::error::$COMMIT is not a commit in this checkout"; exit 1; }

# Every Piri hostname serves the document. piri-0 is the one a node running one
# Piri per storage volume always has; a node with a single Piri still names its
# hostname in PIRI_HOSTNAME.
suffix=$(sed -nE 's/^PIRI_HOSTNAME_SUFFIX=(.*)$/\1/p' "$env_file" | tail -1)
if [ -n "$suffix" ]; then
  host="piri-0.$suffix"
else
  host=$(sed -nE 's/^PIRI_HOSTNAME=(.*)$/\1/p' "$env_file" | tail -1)
fi
[ -n "$host" ] || { echo "::error::no PIRI_HOSTNAME_SUFFIX or PIRI_HOSTNAME in $env_file"; exit 1; }

url="https://$host/.well-known/filone-node-status.json"
deadline=$(($(date +%s) + 60 * 60))
echo "waiting for $NODE at $url to report ${COMMIT:0:7} or a descendant"
while :; do
  # reconcile, not apps: it is stamped on every pass, so a commit that deployed
  # neither project still advances it. apps would sit still and this would wait
  # out the full hour on a docs merge.
  reported=$(curl --silent --max-time 10 --fail "$url" 2>/dev/null |
    jq -r '.projects.reconcile.revision // empty' 2>/dev/null || true)

  if [ -z "$reported" ]; then
    echo "  no revision reported yet"
  elif ! git cat-file -e "$reported^{commit}" 2>/dev/null; then
    echo "  reports $reported, which is not in this checkout"
  elif git merge-base --is-ancestor "$COMMIT" "$reported"; then
    echo "  the node is on ${reported:0:7}"
    exit 0
  else
    echo "  still on ${reported:0:7}"
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::$NODE did not reach ${COMMIT:0:7} within 60 minutes"
    exit 1
  fi
  sleep 60
done
