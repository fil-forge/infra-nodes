#!/usr/bin/env bash
# List the prod nodes Promote to prod opens a pull request for, as a GitHub
# Actions matrix.
#
# Usage:
#   scripts/ci/promote-prod/select.sh
#
# A prod node is a directory under nodes/prod/ that holds a node.env, as
# test-nodes/select.sh and the Makefile find nodes. Each gets a pull request of
# its own, so one region can be upgraded without the others.
#
# Prints {"include":[{"node":"prod/us-east-2"},...]}. In GitHub Actions it also
# writes matrix and has_nodes (true or false) to $GITHUB_OUTPUT, because a
# matrix with no entries fails the job that uses it.
set -euo pipefail

[ $# -eq 0 ] || { echo "usage: scripts/ci/promote-prod/select.sh" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

matrix=$(find nodes/prod -mindepth 2 -maxdepth 2 -name node.env 2>/dev/null \
  | sed 's|^nodes/||; s|/node.env$||' | sort \
  | jq -Rnc '{include: [inputs | {node: .}]}')
has_nodes=$(jq -r '.include | length > 0' <<<"$matrix")
[ "$has_nodes" = true ] || echo "::notice::no prod node to promote: nodes/prod/ holds no node.env"

echo "$matrix"
if [ -n "${GITHUB_OUTPUT-}" ]; then
  echo "matrix=$matrix" >>"$GITHUB_OUTPUT"
  echo "has_nodes=$has_nodes" >>"$GITHUB_OUTPUT"
fi
