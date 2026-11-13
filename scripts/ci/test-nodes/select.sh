#!/usr/bin/env bash
# Choose the nodes Test nodes runs on, as a GitHub Actions matrix.
#
# Usage:
#   scripts/ci/test-nodes/select.sh [<stages> [<nodes>]]
#
# Both arguments are comma-separated lists, because a workflow_dispatch input
# cannot be an array. An empty list means every stage, or every node of the
# chosen stages:
#
#   scripts/ci/test-nodes/select.sh                       every node
#   scripts/ci/test-nodes/select.sh dev                   every dev node
#   scripts/ci/test-nodes/select.sh dev,staging           every dev and staging node
#   scripts/ci/test-nodes/select.sh "" staging/eu-central-3
#   scripts/ci/test-nodes/select.sh staging staging/eu-central-3
#
# An unknown stage or node, or a node outside the chosen stages, fails loudly
# rather than passing with nothing tested.
#
# Every stage in the table has a node, so a selection that passes these checks
# is never empty.
#
# Prints {"include":[{"node":...,"env":...}]}, and in GitHub Actions writes it
# to $GITHUB_OUTPUT as matrix.
set -euo pipefail

# Each node, and the GitHub Environment holding the Hilt partner key for its
# stage. Several nodes of one stage share its Environment. Prod nodes stay out
# until FIL-1491 finds a credential that cannot reach customer tenants.
NODES='[
  {"node": "dev", "env": "dev"},
  {"node": "staging/eu-central-3", "env": "staging"}
]'

usage="usage: scripts/ci/test-nodes/select.sh [<stages> [<nodes>]]"
[ $# -le 2 ] || { echo "$usage" >&2; exit 2; }

matrix=$(jq -nc --arg stages "${1-}" --arg nodes "${2-}" --argjson table "$NODES" '
  # Splits a comma-separated list, dropping the spaces a person may type
  # after a comma and the empty entries a stray comma leaves.
  def list: split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""));

  ($stages | list) as $wanted_stages
  | ($nodes | list) as $wanted_nodes
  | ($table | map(.env) | unique) as $known_stages
  | ($wanted_stages - $known_stages) as $unknown_stages
  | ($wanted_nodes - ($table | map(.node))) as $unknown_nodes
  | if ($unknown_stages | length) > 0 then
      error("unknown stage \($unknown_stages | join(", ")); the stages are \($known_stages | join(", "))")
    elif ($unknown_nodes | length) > 0 then
      error("unknown node \($unknown_nodes | join(", ")); the nodes are listed in NODES in scripts/ci/test-nodes/select.sh")
    else . end
  | [$table[] | select(($wanted_stages | length) == 0 or (.env | IN($wanted_stages[])))] as $in_stages
  | ($wanted_nodes - ($in_stages | map(.node))) as $outside
  | if ($outside | length) > 0 then
      error("node \($outside | join(", ")) is not in stage \($wanted_stages | join(", "))")
    else . end
  | {include: [$in_stages[] | select(($wanted_nodes | length) == 0 or (.node | IN($wanted_nodes[])))]}
') || {
  echo "::error::could not select the nodes to test; see the error above" >&2
  exit 1
}

echo "$matrix"
if [ -n "${GITHUB_OUTPUT-}" ]; then
  echo "matrix=$matrix" >>"$GITHUB_OUTPUT"
fi
