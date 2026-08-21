#!/usr/bin/env bash
# Start Piri and Ingot on a new node for the first time, and check that the node
# actually works.
#
# Runs after onboarding. Piri's first `piri init` calls the registrar for
# approval and gets a 403 for any DID that is not on the delegator's allow list,
# so running this before scripts/operator/onboard.sh produces a crash loop that
# names nothing useful.
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
       Run scripts/operator/onboard.sh from a machine with central credentials.
       docs/RUNBOOK.md has the manual fallback for as long as the onboarding
       Lambda does not exist."

echo "  Piri:  $(bao_get piri did)"
echo "  Ingot: $(bao_get ingot did)"

# --- 2. Start ---------------------------------------------------------------

echo "[2/3] Starting"
# Everything here is the ordinary deploy path. Provisioning apps adds no step of
# its own, which is the point: the first start and every later one run the same
# code.
"$SCRIPT_DIR/deploy-apps.sh"

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

echo
echo "=== node provisioned ==="
echo "Last step: systemctl enable --now filone-reconcile.timer"
