#!/usr/bin/env bash
# Record how one node's Test nodes job ended, for the report job to collect.
#
# Usage:
#   scripts/ci/test-nodes/result.sh <file>
#
# Everything comes from the environment, as test-nodes.yml passes it:
#
#   NODE              the node tested
#   WAITED            true when the job waited for the node to reach the
#                     pushed commit, which only a push does
#   E2E               true when the node's stage gets the end-to-end test, as
#                     the select job's matrix says; false skips it and its
#                     cleanup on purpose
#   WAIT_OUTCOME      the outcome of each step, as steps.<id>.outcome gives it
#   SMOKE_OUTCOME
#   E2E_OUTCOME
#   CLEANUP_OUTCOME
#   E2E_FAILED_OP     the operation that failed, from e2e-test.sh
#   LEFTOVER_TENANT   what cleanup left behind, from e2e-test.sh
#   LEFTOVER_BUCKET
#
# Writes one JSON object to <file>:
#
#   node, failed_step   the first step that did not succeed: wait, smoke, e2e,
#                       cleanup, or setup for a step before them; empty when
#                       every step passed
#   outcome             that step's outcome: failure, or cancelled when the job
#                       was cancelled or hit its time limit during it
#   failed_op, cleanup_outcome, leftover_tenant, leftover_bucket
#
# The outcome of a step that never ran is `skipped`, so a step that should have
# run and was skipped means a step before it failed.
set -euo pipefail

main() {
  local file="${1-}"
  [ -n "$file" ] || { echo "usage: scripts/ci/test-nodes/result.sh <file>" >&2; exit 2; }

  local failed_step="" outcome="success"
  if [ "$WAITED" = true ]; then
    check_step wait "$WAIT_OUTCOME"
  fi
  check_step smoke "$SMOKE_OUTCOME"
  case "$E2E" in
    true)
      check_step e2e "$E2E_OUTCOME"
      check_step cleanup "$CLEANUP_OUTCOME"
      ;;
    # The workflow skips both steps for such a node. Any other outcome means
    # the matrix and the workflow disagree, which is worth an alert.
    false)
      check_skipped e2e "$E2E_OUTCOME"
      check_skipped cleanup "$CLEANUP_OUTCOME"
      ;;
    *) echo "E2E must be true or false, got '$E2E'" >&2; exit 2 ;;
  esac

  jq -n \
    --arg node "$NODE" \
    --arg failed_step "$failed_step" \
    --arg outcome "$outcome" \
    --arg failed_op "${E2E_FAILED_OP-}" \
    --arg cleanup_outcome "$CLEANUP_OUTCOME" \
    --arg leftover_tenant "${LEFTOVER_TENANT-}" \
    --arg leftover_bucket "${LEFTOVER_BUCKET-}" \
    '$ARGS.named' >"$file"
  cat "$file"
}

# check_step — record the step as the failed one, unless an earlier step
# already is. A skipped step blames whatever ran before it.
check_step() {
  local step="$1" step_outcome="$2"
  [ -z "$failed_step" ] || return 0
  case "$step_outcome" in
    success) ;;
    skipped)
      failed_step=setup
      outcome=failure
      ;;
    failure | cancelled)
      failed_step="$step"
      outcome="$step_outcome"
      ;;
    *) echo "unknown outcome for $step: '$step_outcome'" >&2; exit 2 ;;
  esac
}

# check_skipped — a step that must not run on this node, recorded as the failed
# one if it ran anyway.
check_skipped() {
  local step="$1" step_outcome="$2"
  [ -z "$failed_step" ] || return 0
  case "$step_outcome" in
    skipped) ;;
    success | failure | cancelled)
      failed_step="$step"
      outcome=failure
      ;;
    *) echo "unknown outcome for $step: '$step_outcome'" >&2; exit 2 ;;
  esac
}

main "$@"
