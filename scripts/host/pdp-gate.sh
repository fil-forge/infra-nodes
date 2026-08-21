#!/usr/bin/env bash
# Wait until restarting Piri will not cost a proof.
#
# `piri status upgrade-check` answers this directly, by exit code:
#   0  safe
#   1  proving, or in a challenge window it has not proven yet
#   2  cannot tell
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

deadline=$(( $(date +%s) + PDP_GATE_TIMEOUT ))
saw_unsafe=0

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
      saw_unsafe=1
      echo "  not safe: $output"
      ;;
    *)
      # Piri is up but cannot answer — most often a node that has not
      # registered a proof set yet, which is exactly the state a first deploy
      # is in.
      echo "  cannot determine: $output"
      ;;
  esac

  if [ "$(date +%s)" -ge "$deadline" ]; then
    if [ "$saw_unsafe" -eq 1 ]; then
      die "Piri has been unsafe to restart for ${PDP_GATE_TIMEOUT}s. Deploy aborted rather than
       risking a missed proof. Re-run once the challenge window has passed, or set
       PDP_GATE_TIMEOUT higher if the proving period is longer than this."
    fi
    # Never once said "not safe" — it only ever failed to answer. A node with no
    # proof set has no proof to miss, so proceed and say so loudly.
    echo "  WARNING: Piri never reported its proving state; proceeding after ${PDP_GATE_TIMEOUT}s."
    echo "           This is expected before the node has a proof set and worth investigating after."
    exit 0
  fi

  sleep "$PDP_GATE_INTERVAL"
done
