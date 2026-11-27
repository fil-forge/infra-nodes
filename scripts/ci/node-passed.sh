#!/usr/bin/env bash
# Say whether one node passed Test nodes in a run, so a promotion only proposes
# pins its source node has passed with: promote-prod.yml checks
# staging/eu-central-3.
#
# Usage:
#   scripts/ci/node-passed.sh <run id> <node>
#
# Reads the latest attempt of the run's jobs and looks for the one that tested
# the node, named "Test <node>" as test-nodes.yml names each node's job. Only
# that job counts, so a failure on another node holds nothing back.
#
# Prints passed=true or passed=false, and appends the same line to
# $GITHUB_OUTPUT in GitHub Actions. Exits 0 either way. A run with no such job
# fails, because a renamed job would otherwise stop the promotion's pull
# requests from refreshing without a word; so does an API error.
#
# Reads GITHUB_REPOSITORY, fil-forge/infra-nodes by default. gh reads its own
# credentials; the token needs actions: read.
set -euo pipefail

usage="usage: scripts/ci/node-passed.sh <run id> <node>"
[ $# -eq 2 ] || { echo "$usage" >&2; exit 2; }
[[ "$1" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; }
[[ "$2" =~ ^[a-z0-9-]+(/[a-z0-9-]+)?$ ]] || { echo "ERROR: malformed node '$2'" >&2; exit 2; }

JOB="Test $2"
REPO=${GITHUB_REPOSITORY:-fil-forge/infra-nodes}

conclusion=$(gh api --paginate "repos/$REPO/actions/runs/$1/jobs?per_page=100" \
  --jq ".jobs[] | select(.name == \"$JOB\") | .conclusion // \"none\"")
[ -n "$conclusion" ] || {
  echo "::error::run $1 has no job named '$JOB'; has test-nodes.yml renamed it?" >&2
  exit 1
}

passed=false
if [ "$conclusion" = success ]; then
  passed=true
else
  echo "::notice::$JOB ended $conclusion, so the pull requests promoting its pins are left as they are" >&2
fi

echo "passed=$passed"
if [ -n "${GITHUB_OUTPUT-}" ]; then
  echo "passed=$passed" >>"$GITHUB_OUTPUT"
fi
