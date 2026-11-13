#!/usr/bin/env bash
# Choose the nodes Test nodes runs on, as a GitHub Actions matrix.
#
# Usage:
#   scripts/ci/test-nodes/select.sh [<stages> [<nodes>]]
#
# Both arguments are comma-separated lists, because a workflow_dispatch input
# cannot be an array. An empty list means every tested stage, or every node of
# the chosen stages:
#
#   scripts/ci/test-nodes/select.sh                       every node
#   scripts/ci/test-nodes/select.sh dev                   every dev node
#   scripts/ci/test-nodes/select.sh dev,staging           every dev and staging node
#   scripts/ci/test-nodes/select.sh "" staging/eu-central-3
#   scripts/ci/test-nodes/select.sh staging staging/eu-central-3
#
# The nodes are the directories under nodes/ that hold a node.env, each in the
# stage its STAGE names. A node is tested unless its node.env sets
# FILONE_TESTED=false, which a node does while it is being brought up, and only
# if its stage is one of TESTED_STAGES below.
#
# An unknown stage or node, a node that is not tested, or a node outside the
# chosen stages fails loudly rather than passing with nothing tested. A stage
# whose every node sets FILONE_TESTED=false selects nothing, and has_nodes
# says so.
#
# Prints {"include":[{"node":...,"env":...}]}, where env is the GitHub
# Environment holding the stage's Hilt partner key. In GitHub Actions it also
# writes matrix and has_nodes (true or false) to $GITHUB_OUTPUT, because a
# matrix with no entries fails the job that uses it.
set -euo pipefail

# The stages with a GitHub Environment named after them, holding the partner key
# the end-to-end test uses. Prod stays out until FIL-1491 finds a credential
# that cannot reach customer tenants.
TESTED_STAGES='["dev", "staging"]'

usage="usage: scripts/ci/test-nodes/select.sh [<stages> [<nodes>]]"
[ $# -le 2 ] || { echo "$usage" >&2; exit 2; }

main() {
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  cd "$ROOT"

  local nodes
  nodes=$(read_nodes)

  local matrix
  matrix=$(jq -nc --arg stages "${1-}" --arg nodes "${2-}" --argjson all "$nodes" --argjson tested_stages "$TESTED_STAGES" '
    # Splits a comma-separated list, dropping the spaces a person may type
    # after a comma and the empty entries a stray comma leaves.
    def list: split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""));

    ($stages | list) as $wanted_stages
    | ($nodes | list) as $wanted_nodes
    | [$all[] | select(.tested and (.stage | IN($tested_stages[])))] as $table
    | ($wanted_stages - $tested_stages) as $unknown_stages
    | ($wanted_nodes - ($all | map(.node))) as $unknown_nodes
    | ($wanted_nodes - ($table | map(.node)) - $unknown_nodes) as $untested_nodes
    | if ($unknown_stages | length) > 0 then
        error("stage \($unknown_stages | join(", ")) is not tested; the tested stages are \($tested_stages | join(", "))")
      elif ($unknown_nodes | length) > 0 then
        error("unknown node \($unknown_nodes | join(", ")); a node is a directory under nodes/ holding a node.env")
      elif ($untested_nodes | length) > 0 then
        error("node \($untested_nodes | join(", ")) is not tested: its node.env sets FILONE_TESTED=false, or its stage is not one of \($tested_stages | join(", "))")
      else . end
    | [$table[] | select(($wanted_stages | length) == 0 or (.stage | IN($wanted_stages[])))] as $in_stages
    | ($wanted_nodes - ($in_stages | map(.node))) as $outside
    | if ($outside | length) > 0 then
        error("node \($outside | join(", ")) is not in stage \($wanted_stages | join(", "))")
      else . end
    | {include: [$in_stages[]
        | select(($wanted_nodes | length) == 0 or (.node | IN($wanted_nodes[])))
        | {node, env: .stage}]}
  ') || {
    echo "::error::could not select the nodes to test; see the error above" >&2
    exit 1
  }

  local has_nodes
  has_nodes=$(jq -r '.include | length > 0' <<<"$matrix")
  [ "$has_nodes" = true ] || echo "::notice::no node to test: every node of the chosen stages sets FILONE_TESTED=false"

  echo "$matrix"
  if [ -n "${GITHUB_OUTPUT-}" ]; then
    echo "matrix=$matrix" >>"$GITHUB_OUTPUT"
    echo "has_nodes=$has_nodes" >>"$GITHUB_OUTPUT"
  fi
}

# read_nodes — every node under nodes/, as [{node, stage, tested}]. A node.env
# that contradicts its own path, names no stage, or sets FILONE_TESTED to
# anything but true or false fails the selection.
read_nodes() {
  local nodes='[]' env_file node declared stage tested
  while IFS= read -r env_file; do
    node=${env_file#nodes/}
    node=${node%/node.env}
    declared=$(read_value FILONE_NODE "$env_file")
    [ "$declared" = "$node" ] ||
      { echo "::error::$env_file sets FILONE_NODE=$declared, but it is nodes/$node" >&2; exit 1; }
    stage=$(read_value STAGE "$env_file")
    [ -n "$stage" ] || { echo "::error::$env_file sets no STAGE" >&2; exit 1; }
    tested=$(read_value FILONE_TESTED "$env_file")
    case "$tested" in
      "" | true) tested=true ;;
      false) ;;
      *) echo "::error::$env_file sets FILONE_TESTED=$tested; it must be true or false" >&2; exit 1 ;;
    esac
    nodes=$(jq -c --arg node "$node" --arg stage "$stage" --argjson tested "$tested" \
      '. + [{node: $node, stage: $stage, tested: $tested}]' <<<"$nodes")
  done < <(find nodes -name node.env | sort)
  echo "$nodes"
}

# read_value — the last assignment of a variable in a node.env, the one docker
# compose and the host scripts end up with.
read_value() {
  sed -nE "s/^$1=(.*)\$/\\1/p" "$2" | tail -1
}

main "$@"
