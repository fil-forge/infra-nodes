#!/usr/bin/env bash
# Tests for scripts/ci/test-nodes/result.sh, run from any machine:
#
#   scripts/ci/test-nodes/tests/result.test.sh
#
# Each case sets the step outcomes as test-nodes.yml passes them and checks
# the step the script records as the failed one. Needs bash and jq, as the
# script does.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../result.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/result-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0

pass() { printf '  ok   %s\n' "$1"; }
flunk() {
  printf '  FAIL %s\n' "$1"
  failures=$((failures + 1))
}

# record <e2e> <smoke> <e2e outcome> <cleanup outcome> — the failed_step the
# script writes, after a run that did not wait for a commit.
record() {
  NODE=prod/us-east-2 WAITED=false WAIT_OUTCOME=skipped E2E="$1" \
    SMOKE_OUTCOME="$2" E2E_OUTCOME="$3" CLEANUP_OUTCOME="$4" \
    bash "$SCRIPT" "$WORK/result.json" >/dev/null || return
  jq -r .failed_step "$WORK/result.json"
}

# <description>|<E2E>|<smoke>|<e2e>|<cleanup>|<expected failed_step>
cases=(
  'a node with the e2e test that passed everything|true|success|success|success|'
  'a node without the e2e test that passed its smoke test|false|success|skipped|skipped|'
  'a node without the e2e test that failed its smoke test|false|failure|skipped|skipped|smoke'
  'a node with the e2e test whose e2e step was skipped|true|success|skipped|skipped|setup'
  'a node without the e2e test whose e2e step ran anyway|false|success|success|success|e2e'
)

echo "The failed step"
for case in "${cases[@]}"; do
  IFS='|' read -r description e2e smoke e2e_outcome cleanup expected <<<"$case"
  got=$(record "$e2e" "$smoke" "$e2e_outcome" "$cleanup")
  if [ "$got" = "$expected" ]; then
    pass "$description: '${expected}'"
  else
    flunk "$description: expected '$expected', got '$got'"
  fi
done

echo "Inputs that fail loudly"
if output=$(record maybe success skipped skipped 2>&1); then
  flunk "rejects E2E=maybe: it passed with $output"
elif grep -qF "E2E must be true or false, got 'maybe'" <<<"$output"; then
  pass "rejects E2E=maybe"
else
  flunk "rejects E2E=maybe; got $output"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
