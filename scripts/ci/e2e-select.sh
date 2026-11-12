#!/usr/bin/env bash
# Choose the nodes the end-to-end test runs on, as a GitHub Actions matrix.
#
# Usage:
#   scripts/ci/e2e-select.sh <stage>
#   scripts/ci/e2e-select.sh <stage> <smoke run jobs>
#
# <stage> is all, dev or staging. <smoke run jobs> is a file holding the
# response of GET /repos/{owner}/{repo}/actions/runs/{id}/jobs for a "Smoke
# test" run. With it, only the nodes whose smoke job succeeded are kept: a node
# that failed its smoke test has already alerted, and one that never reached the
# commit would be tested on the previous one.
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

usage="usage: scripts/ci/e2e-select.sh <all|dev|staging> [<smoke run jobs>]"
stage="${1-}"
jobs_file="${2-}"
case "$stage" in
  all | dev | staging) ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

matrix=$(jq -nc --arg stage "$stage" --argjson nodes "$NODES" \
  '{include: [$nodes[] | select($stage == "all" or .env == $stage)]}')

# A smoke run cancelled before its matrix expanded lists no jobs, and a newer
# push has its own run.
if [ -n "$jobs_file" ] && [ "$(jq '.jobs | length' "$jobs_file")" -eq 0 ]; then
  matrix='{"include":[]}'
elif [ -n "$jobs_file" ]; then
  # smoke.yml's matrix job is named "Smoke test", and GitHub appends the matrix
  # value. A node with no such job means one of the names changed, and skipping
  # it would turn the test off without a word.
  missing=$(jq -r --argjson matrix "$matrix" '
    [.jobs[].name] as $names
    | $matrix.include[].node
    | select(("Smoke test (" + . + ")") as $job | any($names[]; . == $job) | not)
  ' "$jobs_file")
  if [ -n "$missing" ]; then
    echo "::error::the smoke run has no job for: $(tr '\n' ' ' <<<"$missing")" >&2
    exit 1
  fi
  matrix=$(jq -c --argjson matrix "$matrix" '
    [.jobs[] | select(.conclusion == "success") | .name] as $passed
    | {include: [$matrix.include[]
        | select(("Smoke test (" + .node + ")") as $job | any($passed[]; . == $job))]}
  ' "$jobs_file")
fi

has_nodes=$(jq -r '.include | length > 0' <<<"$matrix")
echo "$matrix"
if [ -n "${GITHUB_OUTPUT-}" ]; then
  echo "matrix=$matrix" >>"$GITHUB_OUTPUT"
  echo "has_nodes=$has_nodes" >>"$GITHUB_OUTPUT"
fi
