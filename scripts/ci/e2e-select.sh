#!/usr/bin/env bash
# Choose the nodes the end-to-end test runs on, as a GitHub Actions matrix.
#
# Usage:
#   scripts/ci/e2e-select.sh <all|dev|staging>
#
# Prints {"include":[{"node":...,"env":...}]}. In GitHub Actions it also writes
# matrix and has_nodes (true or false) to $GITHUB_OUTPUT, because a matrix with
# no entries fails the job that uses it.
set -euo pipefail

# Each node, and the GitHub Environment holding the Hilt partner key for its
# stage. Prod nodes stay out until FIL-1491 finds a credential that cannot reach
# customer tenants.
NODES='[
  {"node": "dev", "env": "dev"},
  {"node": "staging/eu-central-3", "env": "staging"}
]'

stage="${1-}"
case "$stage" in
  all | dev | staging) ;;
  *) echo "usage: scripts/ci/e2e-select.sh <all|dev|staging>" >&2; exit 2 ;;
esac

matrix=$(jq -nc --arg stage "$stage" --argjson nodes "$NODES" \
  '{include: [$nodes[] | select($stage == "all" or .env == $stage)]}')
has_nodes=$(jq -r '.include | length > 0' <<<"$matrix")

echo "$matrix"
if [ -n "${GITHUB_OUTPUT-}" ]; then
  echo "matrix=$matrix" >>"$GITHUB_OUTPUT"
  echo "has_nodes=$has_nodes" >>"$GITHUB_OUTPUT"
fi
