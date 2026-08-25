#!/usr/bin/env bash
# Wait until restarting Piri will not cost a proof.
#
# `piri status upgrade-check` answers this directly, by exit code:
#   0  safe
#   1  proving, or in a challenge window it has not proven yet
#   2  cannot tell
#
# It fails closed. A node that owes proofs and will not say whether one is in
# flight blocks the deploy until it answers or the timeout runs out; only a node
# with no proof set at all skips the wait.
#
# The gate runs in dev as well as production, because a gate that only runs in
# production is a gate nobody has tested.
#
# Env:
#   PDP_GATE_TIMEOUT   seconds to wait (default 2700, comfortably past one
#                      calibration proving period)
#   PDP_GATE_INTERVAL  seconds between polls (default 30)
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

PDP_GATE_TIMEOUT="${PDP_GATE_TIMEOUT:-2700}"
PDP_GATE_INTERVAL="${PDP_GATE_INTERVAL:-30}"
PIRI_CONTAINER=filone-piri
PIRI_CONFIG=/data/piri/piri-config.toml

# Nothing to interrupt. A node that has not started Piri yet, or whose Piri is
# already down, has no proof in flight.
if ! docker inspect -f '{{.State.Running}}' "$PIRI_CONTAINER" 2>/dev/null | grep -q true; then
  echo "  Piri is not running; nothing to wait for"
  exit 0
fi

# A node with no proof set has no proof to miss. That is the state a first
# deploy is in, and it is also the one state where `upgrade-check` cannot answer
# for a benign reason, so it is established here rather than inferred from the
# check failing to answer. Everything past this point owes proofs, and a check
# that will not answer is a reason to stop.
if ! docker exec -i "$PIRI_CONTAINER" \
  grep -q proof_set "$PIRI_CONFIG" >/dev/null 2>&1; then
  echo "  Piri has no proof set yet; nothing to wait for"
  exit 0
fi

deadline=$(( $(date +%s) + PDP_GATE_TIMEOUT ))

echo "  waiting for a safe window (timeout ${PDP_GATE_TIMEOUT}s)"
while :; do
  set +e
  output="$(docker exec -i "$PIRI_CONTAINER" \
    piri status upgrade-check --config "$PIRI_CONFIG" 2>&1)"
  verdict=$?
  set -e

  case "$verdict" in
    0)
      echo "  safe to restart"
      exit 0
      ;;
    1)
      # A definite no. Piri is proving or owes a proof this window.
      echo "  not safe: $output"
      ;;
    *)
      # Piri is up and owes proofs but will not say whether one is in flight,
      # most often because the chain RPC is unreachable. Treated as unsafe: the
      # one benign cause was ruled out before the loop.
      echo "  cannot determine: $output"
      ;;
  esac

  if [ "$(date +%s)" -ge "$deadline" ]; then
    die "Piri has not reported a safe restart window in ${PDP_GATE_TIMEOUT}s. Deploy aborted
       rather than risking a missed proof. The last answer was:
         $output
       Re-run once the challenge window has passed, or raise PDP_GATE_TIMEOUT if the
       proving period is longer than this. If Piri is wedged and cannot answer at all,
       'docker stop filone-piri' and re-run: a Piri that is already down has no proof in
       flight, and the deploy will proceed."
  fi

  sleep "$PDP_GATE_INTERVAL"
done
