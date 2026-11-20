#!/usr/bin/env bash
# Say whether staging passed Test nodes in a run, so Promote to prod only
# proposes pins staging has passed with.
#
# Usage:
#   scripts/ci/promote-prod/staging-passed.sh <run id>
#
# Reads the latest attempt of the run's jobs and looks for the one that tested
# staging/eu-central-3, the node prod takes its pins from. Its job name,
# "Test staging/eu-central-3", is the one test-nodes.yml gives each node's job.
# A dev failure does not hold prod back: only staging's job counts.
#
# Prints passed=true or passed=false, and appends the same line to
# $GITHUB_OUTPUT in GitHub Actions. Exits 0 either way. A run with no such job
# fails, because a renamed job would otherwise stop prod's pull requests from
# refreshing without a word; so does an API error.
#
# Reads GITHUB_REPOSITORY, fil-forge/infra-nodes by default. gh reads its own
# credentials; the token needs actions: read.
set -euo pipefail

[ $# -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]] ||
  { echo "usage: scripts/ci/promote-prod/staging-passed.sh <run id>" >&2; exit 2; }

JOB="Test staging/eu-central-3"
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
  echo "::notice::$JOB ended $conclusion, so prod's pull requests are left as they are" >&2
fi

echo "passed=$passed"
if [ -n "${GITHUB_OUTPUT-}" ]; then
  echo "passed=$passed" >>"$GITHUB_OUTPUT"
fi
