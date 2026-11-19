#!/usr/bin/env bash
# Tests for scripts/ci/test-nodes/select.sh, run from any machine:
#
#   scripts/ci/test-nodes/tests/select.test.sh
#
# The script reads every node.env under nodes/ next to its own checkout, so
# each case copies it into a temporary tree that holds fixture nodes instead of
# the real ones. Needs bash and jq, as the script does.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../select.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/select-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0

pass() { printf '  ok   %s\n' "$1"; }
flunk() {
  printf '  FAIL %s\n' "$1"
  failures=$((failures + 1))
}

# make_tree <dir> — a checkout with select.sh and four fixture nodes: one per
# stage, and a second prod node that is still being brought up.
make_tree() {
  local tree="$1"
  mkdir -p "$tree/scripts/ci/test-nodes"
  cp "$SCRIPT" "$tree/scripts/ci/test-nodes/select.sh"
  add_node "$tree" dev dev
  add_node "$tree" staging/eu-central-3 staging
  add_node "$tree" prod/us-east-2 prod
  add_node "$tree" prod/us-east-3 prod FILONE_TESTED=false
}

# add_node <tree> <node> <stage> [<extra line>]
add_node() {
  mkdir -p "$1/nodes/$2"
  printf 'FILONE_NODE=%s\nSTAGE=%s\n%s\n' "$2" "$3" "${4-}" >"$1/nodes/$2/node.env"
}

# select_in <tree> [<stages> [<nodes>]] — the matrix select.sh prints, compact.
select_in() {
  local tree="$1"
  shift
  (unset GITHUB_OUTPUT; bash "$tree/scripts/ci/test-nodes/select.sh" "$@" 2>/dev/null) | jq -c .
}

TREE="$WORK/tree"
make_tree "$TREE"

echo "Each tested node gets the smoke test, and only dev and staging the e2e test"
expected_entries=(
  '{"node":"dev","env":"dev","e2e":true}'
  '{"node":"staging/eu-central-3","env":"staging","e2e":true}'
  '{"node":"prod/us-east-2","env":"","e2e":false}'
)
all_nodes=$(select_in "$TREE")
for entry in "${expected_entries[@]}"; do
  if jq -e --argjson entry "$entry" '.include | index([$entry]) != null' <<<"$all_nodes" >/dev/null; then
    pass "selects $entry"
  else
    flunk "selects $entry; got $all_nodes"
  fi
done

echo "Narrowing the selection"
selection_cases=(
  'stage prod|prod||{"include":[{"node":"prod/us-east-2","env":"","e2e":false}]}'
  'node prod/us-east-2||prod/us-east-2|{"include":[{"node":"prod/us-east-2","env":"","e2e":false}]}'
  'stage dev, unchanged|dev||{"include":[{"node":"dev","env":"dev","e2e":true}]}'
  'every node, leaving out a FILONE_TESTED=false node|||{"include":[{"node":"dev","env":"dev","e2e":true},{"node":"prod/us-east-2","env":"","e2e":false},{"node":"staging/eu-central-3","env":"staging","e2e":true}]}'
)
for case in "${selection_cases[@]}"; do
  IFS='|' read -r description stages nodes expected <<<"$case"
  got=$(select_in "$TREE" "$stages" "$nodes")
  if [ "$got" = "$expected" ]; then
    pass "$description"
  else
    flunk "$description: expected $expected, got $got"
  fi
done

echo "Selections that fail loudly"
rejection_cases=(
  'an unknown stage|qa||stage qa is not tested'
  'a node with FILONE_TESTED=false||prod/us-east-3|node prod/us-east-3 is not tested'
)
for case in "${rejection_cases[@]}"; do
  IFS='|' read -r description stages nodes message <<<"$case"
  if output=$(bash "$TREE/scripts/ci/test-nodes/select.sh" "$stages" "$nodes" 2>&1); then
    flunk "rejects $description: it passed with $output"
  elif grep -qF "$message" <<<"$output"; then
    pass "rejects $description"
  else
    flunk "rejects $description with '$message'; got $output"
  fi
done

echo "A stage whose every node sets FILONE_TESTED=false"
# prod/us-east-2 before step 7 of bringing it up: the job must be skipped,
# because a matrix with no entries fails it.
UNTESTED="$WORK/untested"
mkdir -p "$UNTESTED/scripts/ci/test-nodes"
cp "$SCRIPT" "$UNTESTED/scripts/ci/test-nodes/select.sh"
add_node "$UNTESTED" dev dev
add_node "$UNTESTED" prod/us-east-2 prod FILONE_TESTED=false
GITHUB_OUTPUT="$WORK/untested-output" bash "$UNTESTED/scripts/ci/test-nodes/select.sh" prod >/dev/null 2>&1
if grep -qx 'has_nodes=false' "$WORK/untested-output"; then
  pass "writes has_nodes=false"
else
  flunk "writes has_nodes=false; got $(cat "$WORK/untested-output")"
fi

# An E2E_STAGES entry outside TESTED_STAGES would never run its e2e test, so
# the script refuses it instead of selecting without it.
BAD_E2E="$WORK/bad-e2e"
make_tree "$BAD_E2E"
sed -i.orig "s/^E2E_STAGES=.*/E2E_STAGES='[\"dev\", \"staging\", \"qa\"]'/" \
  "$BAD_E2E/scripts/ci/test-nodes/select.sh"
if output=$(bash "$BAD_E2E/scripts/ci/test-nodes/select.sh" 2>&1); then
  flunk "rejects an E2E_STAGES stage outside TESTED_STAGES: it passed with $output"
elif grep -qF "E2E_STAGES names qa, which is not one of TESTED_STAGES" <<<"$output"; then
  pass "rejects an E2E_STAGES stage outside TESTED_STAGES"
else
  flunk "rejects an E2E_STAGES stage outside TESTED_STAGES; got $output"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
