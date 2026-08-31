#!/usr/bin/env bash
# Start Piri and Ingot on a new node for the first time, and check that the node
# actually works.
#
# Runs after onboarding. Piri's first `piri init` calls the registrar for
# approval and gets a 403 for any DID that is not on the delegator's allow list,
# so running this before central has registered the node produces a crash loop
# that names nothing useful.
set -euo pipefail

# SC2154: PIRI_HOSTNAME and INGOT_HOSTNAME come from the node's node.env,
# which filone_init sources at run time.
# shellcheck disable=SC2154

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

filone_init

echo "=== provision apps ($FILONE_NODE) ==="

# --- 1. What onboarding was supposed to leave behind ------------------------

echo "[1/3] Checking onboarding completed"
bao_is_unsealed || die "OpenBao is sealed; run provision-platform.sh first"

bao_has piri did || die "no Piri DID in OpenBao; run keygen.sh"
bao_has ingot hilt_proof ||
  die "OpenBao has no hilt-to-ingot delegation, so onboarding has not finished.
       onboarding-request.sh prints what Forge Central needs; store-hilt-proof.sh
       installs the delegation they send back."

echo "  Piri:  $(bao_get piri did)"
# Ingot has two identities: the did:web it signs as, and the key that document
# publishes. The delegation's audience is the did:web, so that one leads.
echo "  Ingot: $INGOT_DID (key: $(bao_get ingot did))"

# --- 2. Start ---------------------------------------------------------------

# True on a node whose Piri has never finished `piri init`. Mirrors the first two
# conditions of the entrypoint's skip test, read from the host so this needs no
# container. A re-init triggered by a changed base config is not a first setup,
# and does not stream.
piri_needs_init() {
  local config=/mnt/filone/data/piri/piri-config.toml
  [ -f "$config" ] && grep -q proof_set "$config" 2>/dev/null && return 1
  return 0
}

# Run the deploy and print Piri's container log alongside it.
#
# `docker logs --since` by container name each pass, rather than one
# `docker logs -f`: the deploy runs `up -d --force-recreate piri`, which replaces
# the container, and a follower attached to the old container ID exits silently
# at that moment. A fresh call per pass resolves whatever container is current.
run_deploy_streaming_piri_log() {
  # Job control, so the deploy leads a process group of its own and the trap
  # below can signal everything it started. Ctrl+C reaches only the foreground
  # group, which is this script; unforwarded, the deploy runs on orphaned and
  # keeps the deploy lock that its children inherited.
  set -m
  # </dev/null because bao_get runs `docker exec -i`, and a background process
  # that reads the terminal takes SIGTTIN and stops.
  "$SCRIPT_DIR/deploy-apps.sh" </dev/null &
  local deploy_pid=$!
  set +m
  # SC2064: expanding the pid now is the point; the trap must not depend on a
  # local that is out of scope by the time a signal arrives.
  # shellcheck disable=SC2064
  trap "stop_deploy $deploy_pid" INT TERM

  local since next
  since="$(date +%s)"
  while kill -0 "$deploy_pid" 2>/dev/null; do
    # Read the clock before the log, then advance to it. A boundary line printed
    # twice is better than one lost between passes.
    next="$(date +%s)"
    drain_piri_log "$since"
    since="$next"
    sleep 2
  done

  trap - INT TERM
  drain_piri_log "$since"
  wait "$deploy_pid" || die "deploy-apps.sh failed"
}

# Take the deploy down on Ctrl+C. Signals the group rather than the pid: the
# deploy lock lives on an open file description that every child inherited, and
# one surviving `sleep` holds it for the full hour the next run will wait.
stop_deploy() {
  local deploy_pid="$1"
  echo
  echo "  interrupted; stopping the deploy"
  kill -TERM -- "-$deploy_pid" 2>/dev/null || true
  wait "$deploy_pid" 2>/dev/null || true
  kill -KILL -- "-$deploy_pid" 2>/dev/null || true
  die "interrupted while deploying. Piri may be mid-restart; rerun this script."
}

# Guarded on the container existing: on a first provision the poll starts before
# compose has created it, and `docker logs` on a missing container is an error
# per pass.
#
# Best-effort past that guard. The deploy runs `up -d --force-recreate piri`, so
# the container can go away between the check and the read, and under
# `set -euo pipefail` that one expected error would abort provisioning while the
# deploy keeps running and keeps the deploy lock. The next pass reads whatever
# container is current.
drain_piri_log() {
  container_exists filone-piri || return 0
  docker logs --since "$1" filone-piri 2>&1 | sed 's/^/  piri | /' || true
}

echo "[2/3] Starting"
# Everything here is the ordinary deploy path. Provisioning apps adds no step of
# its own, which is the point: the first start and every later one run the same
# code.
if piri_needs_init; then
  # `piri init` registers the provider and creates the proof set, waiting on both
  # transactions. That wait is minutes long and every sign of it living or being
  # stuck is in Piri's log, which nothing else here would show.
  echo "  first Piri start; its log follows, prefixed 'piri |'"
  run_deploy_streaming_piri_log
else
  "$SCRIPT_DIR/deploy-apps.sh"
fi

# --- 3. Acceptance ----------------------------------------------------------

echo "[3/3] Acceptance checks"

check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok    $description"
  else
    echo "  FAIL  $description"
    return 1
  fi
}

failures=0

# "Unsealed" on its own proves nothing about now: OpenBao unseals at startup and
# stays unsealed even after central becomes unreachable. Restarting it is the
# only check that exercises the transit path, and it is the same path a reboot
# or an image bump will take.
seal_roundtrip() {
  docker restart "$FILONE_BAO_CONTAINER" >/dev/null
  for _ in $(seq 1 30); do
    bao_is_unsealed && return 0
    sleep 2
  done
  return 1
}

check "OpenBao restarts and unseals against central" seal_roundtrip ||
  failures=$((failures + 1))

check "Piri answers /readyz" \
  docker exec filone-piri wget -q -O - http://localhost:3000/readyz ||
  failures=$((failures + 1))

check "Ingot answers /health" \
  docker exec filone-ingot curl -sf http://localhost:9000/health ||
  failures=$((failures + 1))

check "Caddy serves $PIRI_HOSTNAME with an issued certificate" \
  curl -sf --max-time 20 "https://$PIRI_HOSTNAME/readyz" ||
  failures=$((failures + 1))

check "Caddy serves $INGOT_HOSTNAME with an issued certificate" \
  curl -sf --max-time 20 "https://$INGOT_HOSTNAME/health" ||
  failures=$((failures + 1))

if [ "$failures" -gt 0 ]; then
  die "$failures acceptance check(s) failed. The node is running but not finished;
       docs/RUNBOOK.md has what each check means when it fails."
fi

# Bootstrap installs the units too, but a node bootstrapped from a revision that
# did not have them yet, or one whose checkout has moved since, reaches this
# point with nothing in /etc/systemd/system for the operator to enable. Only the
# reconcile timer would install them, and it cannot run until it exists.
echo
echo "Installing the systemd units"
sync_systemd_units

echo
echo "=== node provisioned ==="
echo "Last step, both timers:"
echo "  systemctl enable --now filone-reconcile.timer"
echo "  systemctl enable --now filone-seal-token-renew.timer"
