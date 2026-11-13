#!/usr/bin/env bash
# Choose the nodes the end-to-end test runs on, as a GitHub Actions matrix.
#
# Usage:
#   scripts/ci/e2e-select.sh <all|dev|staging>
#   scripts/ci/e2e-select.sh <all|dev|staging> <node>
#
# With a stage alone, every node of that stage. With a node too, that node
# alone, and it must belong to the stage: a node nobody tests fails loudly
# rather than passing with nothing tested.
#
# Prints {"include":[{"node":...,"env":...}]}. In GitHub Actions it also writes
# matrix and has_nodes (true or false) to $GITHUB_OUTPUT, because a matrix with
# no entries fails the job that uses it.
set -euo pipefail

# Each node, and the GitHub Environment holding the Hilt partner key for its
# stage. Several nodes of one stage share its Environment. Prod nodes stay out
# until FIL-1491 finds a credential that cannot reach customer tenants.
NODES='[
  {"node": "dev", "env": "dev"},
  {"node": "staging/eu-central-3", "env": "staging"}
]'

usage="usage: scripts/ci/e2e-select.sh <all|dev|staging> [<node>]"
stage="${1-}"
node="${2-}"
case "$stage" in
  all | dev | staging) ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

matrix=$(jq -nc --arg stage "$stage" --arg node "$node" --argjson nodes "$NODES" '
  {include: [$nodes[]
    | select($stage == "all" or .env == $stage)
    | select($node == "" or .node == $node)]}')
has_nodes=$(jq -r '.include | length > 0' <<<"$matrix")

if [ -n "$node" ] && [ "$has_nodes" = false ]; then
  echo "::error::no node $node in stage $stage; the nodes are listed in NODES in scripts/ci/e2e-select.sh" >&2
  exit 1
fi

echo "$matrix"
if [ -n "${GITHUB_OUTPUT-}" ]; then
  echo "matrix=$matrix" >>"$GITHUB_OUTPUT"
  echo "has_nodes=$has_nodes" >>"$GITHUB_OUTPUT"
fi
