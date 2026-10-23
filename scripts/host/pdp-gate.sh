#!/usr/bin/env bash
# Wait until restarting the named Piris will not cost a proof.
#
# Usage: pdp-gate.sh <piri service>...
#
# An apps deploy gates one Piri at a time, because it recreates them one at a
# time. A platform deploy restarts Postgres under every Piri at once, so it names
# them all and the gate waits until every one of them reports safe in the same
# poll. Gating them one after another would let the first drift back into a
# challenge window while the gate waits on the last.
#
# `piri status upgrade-check` answers the question directly, by exit code:
#   0  safe
#   1  not safe: proving, in a challenge window it has not proven yet, or in a
#      fault state. The output says which.
#   2  cannot tell
#
# It fails closed. A Piri that owes proofs and will not say whether one is in
# flight blocks the deploy until it answers or the timeout runs out; only a Piri
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
# Paths inside the container, the same for every Piri: each one mounts its own
# data directory at /data/piri.
PIRI_CONFIG=/data/piri/piri-config.toml
# Written by `piri init` once it has finished. See the config probe below.
PIRI_BASE_SNAPSHOT=/data/piri/piri-base-config.applied.toml

main() {
  [ "$#" -gt 0 ] || die "usage: pdp-gate.sh <piri service>..."

  local service waiting=()
  for service in "$@"; do
    if owes_proofs "$service"; then
      waiting+=("$service")
    fi
  done
  [ "${#waiting[@]}" -gt 0 ] || exit 0

  local deadline output verdict all_safe last_answers
  deadline=$(( $(date +%s) + PDP_GATE_TIMEOUT ))

  echo "  waiting for a safe window for ${waiting[*]} (timeout ${PDP_GATE_TIMEOUT}s)"
  while :; do
    all_safe=1
    last_answers=""
    for service in "${waiting[@]}"; do
      set +e
      output="$(docker exec -i "filone-$service" \
        piri status upgrade-check --config "$PIRI_CONFIG" 2>&1)"
      verdict=$?
      set -e

      case "$verdict" in
        0)
          echo "  $service: safe to restart"
          ;;
        1)
          # A definite no. Piri's output already says "not safe" and why, so it is
          # printed as it is.
          echo "  $service: $output"
          all_safe=0
          ;;
        *)
          # Piri is up and owes proofs but will not say whether one is in flight,
          # most often because the chain RPC is unreachable. Treated as unsafe: the
          # one benign cause was ruled out before the loop.
          echo "  $service: cannot determine: $output"
          all_safe=0
          ;;
      esac
      last_answers+="
         $service: $output"
    done

    if [ "$all_safe" -eq 1 ]; then
      exit 0
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      die "no safe restart window for ${waiting[*]} within ${PDP_GATE_TIMEOUT}s.
       Deploy aborted rather than risking a missed proof. The last answers were:$last_answers
       Re-run once the challenge window has passed, or raise PDP_GATE_TIMEOUT if the
       proving period is longer than this. If a Piri is wedged and cannot answer at all,
       'docker stop filone-<service>' and re-run: a Piri that is already down has no
       proof in flight, and the deploy will proceed."
    fi

    sleep "$PDP_GATE_INTERVAL"
  done
}

# Whether a restart of this Piri could cost a proof. Returns 1 when there is
# nothing to wait for, and dies when the answer is unknown.
owes_proofs() {
  local service="$1" container="filone-$1"

  # Nothing to interrupt. A Piri that has not started yet, or is already down,
  # has no proof in flight.
  if ! container_running "$container"; then
    echo "  $service is not running; nothing to wait for"
    return 1
  fi

  # A Piri with no proof set has no proof to miss. That is the state a first
  # deploy is in, and it is also the one state where `upgrade-check` cannot answer
  # for a benign reason, so it is established here rather than inferred from the
  # check failing to answer. Everything past this point owes proofs, and a check
  # that will not answer is a reason to stop.
  #
  # The config is looked for before it is read. `piri init` writes it on the first
  # boot, and until init returns there is no file. Folding that case into the read
  # below would report it as a broken `docker exec` — grep exits 2 for a file it
  # cannot open, and the gate would stop a first deploy every time.
  #
  # A missing config is not on its own proof that init never ran. Deleting the file
  # does not release an on-chain proof set, and a Piri already serving from a
  # config it loaded at startup keeps proving without it. So a missing config sends
  # the gate to a second question, below, and only a Piri that answers "init has
  # never completed" skips the wait.
  local config_probe snapshot_probe proof_set_probe
  set +e
  docker exec -i "$container" sh -c 'test -f "$1"' sh "$PIRI_CONFIG" >/dev/null 2>&1
  config_probe=$?
  set -e

  case "$config_probe" in
    0) ;;
    1)
      # `piri init` copies the base config it merged from to PIRI_BASE_SNAPSHOT as
      # its last step, so the snapshot exists only where init has once returned.
      # No snapshot and no config is the state a first deploy is in: nothing on
      # chain, nothing to miss, and interrupting init costs nothing because init
      # is safe to re-run.
      set +e
      docker exec -i "$container" sh -c 'test -f "$1"' sh "$PIRI_BASE_SNAPSHOT" >/dev/null 2>&1
      snapshot_probe=$?
      set -e

      case "$snapshot_probe" in
        1)
          echo "  $service has not run init yet; nothing to wait for"
          return 1
          ;;
        0)
          die "$PIRI_CONFIG is gone from $container but $PIRI_BASE_SNAPSHOT is still there,
       so init has completed before and this Piri may hold a proof set and owe a proof.
       The deploy stops rather than restarting it. Restore the config, or if this Piri
       is being decommissioned, 'docker stop $container' and re-run: a Piri that is
       already down has no proof in flight."
          ;;
        *)
          die "could not look for $PIRI_BASE_SNAPSHOT in $container (docker exec exited $snapshot_probe).
       Whether this Piri owes a proof is unknown, so the deploy stops rather than restarting it."
          ;;
      esac
      ;;
    *)
      die "could not look for $PIRI_CONFIG in $container (docker exec exited $config_probe).
       Whether this Piri owes a proof is unknown, so the deploy stops rather than restarting it."
      ;;
  esac

  # Only grep's own exit 1 counts as "no proof set". The file is known to exist by
  # now, so a grep that exits 2 found it unreadable, and a docker exec that could
  # not run at all exits 125 or higher. Reading either as an absent proof set
  # would skip the gate on a daemon hiccup — the failure this check exists to
  # close.
  set +e
  docker exec -i "$container" grep -q proof_set "$PIRI_CONFIG" >/dev/null 2>&1
  proof_set_probe=$?
  set -e

  case "$proof_set_probe" in
    0) return 0 ;;
    1)
      echo "  $service has no proof set yet; nothing to wait for"
      return 1
      ;;
    *)
      die "could not read $PIRI_CONFIG in $container (exit $proof_set_probe).
       Whether this Piri owes a proof is unknown, so the deploy stops rather than restarting it."
      ;;
  esac
}

main "$@"
