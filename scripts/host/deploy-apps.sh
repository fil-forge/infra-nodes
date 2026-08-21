#!/usr/bin/env bash
# Bring Piri and Ingot to what the checkout says they should be.
#
# Runs on the node, as root, from the reconcile timer or by hand. The one thing
# it does that the platform deploy does not: wait for Piri's proving window
# before restarting Piri, because a restart in the wrong minute is a missed
# proof.
#
# Idempotent. A run that changes nothing renders identical files, finds the
# running images already correct, restarts nothing and never touches the gate.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

filone_init

echo "=== deploy apps ($FILONE_NODE) ==="

bao_is_unsealed || die "OpenBao is sealed; run deploy-platform.sh first"

[ "$PAYER_ADDRESS" != "0x0000000000000000000000000000000000000000" ] ||
  die "PAYER_ADDRESS in nodes/$FILONE_NODE/node.env is still the placeholder.
       Read the real address from the central dev stage (docs/RUNBOOK.md says how) and commit it."

piri_changed=0
ingot_changed=0

# render_template and write_secret_file report "changed" by exit status, which
# `set -e` would otherwise read as a failure on every unchanged file.
mark() {
  local -n flag="$1"
  shift
  if "$@"; then flag=1; fi
}

# --- 1. Render --------------------------------------------------------------

echo "[1/5] Rendering configuration and keys"

# Piri's identity and its owner wallet. The trailing newline on the PEM is
# deliberate: OpenBao returns the value without one and a PEM whose END line
# runs into EOF is not reliably decodable.
mark piri_changed write_secret_file "$FILONE_SECRETS_DIR/piri.pem" "$(bao_get piri identity_pem)
"
mark piri_changed write_secret_file "$FILONE_SECRETS_DIR/piri-owner-wallet.hex" \
  "$(piri_wallet_hex "$(bao_get piri owner_wallet_key)")"

# Piri's base config carries no secret, only addresses and URLs from node.env.
mark piri_changed render_template \
  "$FILONE_NODE_DIR/apps/config/piri/piri-base-config.toml.tpl" \
  "$FILONE_SECRETS_DIR/piri-base-config.toml"

PIRI_POSTGRES_PASSWORD="$(bao_get postgres piri_password)"
CHAIN_RPC_TOKEN="$(bao_get external chain_rpc_token)"
export PIRI_POSTGRES_PASSWORD CHAIN_RPC_TOKEN
mark piri_changed render_template \
  "$FILONE_NODE_DIR/apps/templates/apps.env.tpl" \
  "$FILONE_SECRETS_DIR/apps.env"

# Ingot's identity, its config (which embeds the DSN and the root credentials)
# and hilt's delegation to it.
mark ingot_changed write_secret_file "$FILONE_SECRETS_DIR/ingot.pem" "$(bao_get ingot identity_pem)
"

INGOT_POSTGRES_PASSWORD="$(bao_get postgres ingot_password)"
INGOT_ROOT_ACCESS_KEY="$(bao_get ingot root_access_key)"
INGOT_ROOT_SECRET_KEY="$(bao_get ingot root_secret_key)"
export INGOT_POSTGRES_PASSWORD INGOT_ROOT_ACCESS_KEY INGOT_ROOT_SECRET_KEY
mark ingot_changed render_template \
  "$FILONE_NODE_DIR/apps/config/ingot/config.yaml.tpl" \
  "$FILONE_SECRETS_DIR/ingot-config.yaml"

# Issued by hilt during onboarding, because it names an Ingot DID that does not
# exist until this node is provisioned.
bao_has ingot hilt_proof ||
  die "OpenBao has no hilt-to-ingot delegation. Run scripts/operator/onboard.sh; without it
       every S3 request Ingot makes to hilt is refused."
mark ingot_changed write_secret_file "$FILONE_SECRETS_DIR/hilt-ingot-proof.txt" "$(bao_get ingot hilt_proof)
"

# --- 2. Pull ----------------------------------------------------------------

echo "[2/5] Pulling images"
# Before the gate, not after. Pulling can take minutes, and doing it inside the
# safe window would spend the window on a download.
compose_apps pull --quiet

# shellcheck disable=SC1091
. "$FILONE_NODE_DIR/apps/versions.env"

# A moving tag resolving to a new digest is invisible to compose, which compares
# the tag string, so the running image id is compared against the pulled one.
image_differs() {
  local container="$1" wanted="$2" running desired
  running="$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || echo none)"
  desired="$(docker image inspect -f '{{.Id}}' "$wanted" 2>/dev/null || echo unknown)"
  [ "$running" != "$desired" ]
}

mark piri_changed image_differs filone-piri "$PIRI_IMAGE"
mark ingot_changed image_differs filone-ingot "$INGOT_IMAGE"

# And the definition itself: an edit to node.env changes a service's environment
# or its command without changing any rendered file, and compose would recreate
# the container for it. That has to go through the gate like everything else, so
# it is detected here rather than discovered by `up -d`.
service_config_hash() {
  compose_apps config --format json |
    python3 -c '
import hashlib, json, sys
service = json.load(sys.stdin)["services"][sys.argv[1]]
print(hashlib.sha256(json.dumps(service, sort_keys=True).encode()).hexdigest())
' "$1"
}

config_changed() {
  local service="$1" current="$2" previous
  previous="$(cat "$FILONE_STATE_DIR/apps-$service.sha256" 2>/dev/null || true)"
  [ "$current" != "$previous" ]
}

piri_config_hash="$(service_config_hash piri)"
ingot_config_hash="$(service_config_hash ingot)"
mark piri_changed config_changed piri "$piri_config_hash"
mark ingot_changed config_changed ingot "$ingot_config_hash"

# --- 3. Piri ----------------------------------------------------------------

echo "[3/5] Piri"
if [ "$piri_changed" -eq 1 ]; then
  echo "  something changed; waiting for a safe restart window"
  "$SCRIPT_DIR/pdp-gate.sh"
  # --force-recreate because most of what changes here is the *content* of a
  # bind-mounted file — a re-rendered config, a rotated password, a new proof.
  # Compose decides recreation from the service definition, which those leave
  # untouched, so a plain `up -d` would report success and leave the old
  # process running with the old secret.
  compose_apps up -d --force-recreate piri
else
  echo "  nothing changed"
  compose_apps up -d --no-recreate piri
fi

# --- 4. Ingot ---------------------------------------------------------------

# After Piri: Ingot writes through to it, and starting against a Piri that is
# still coming up produces a burst of failures for no reason.
echo "[4/5] Ingot"
if [ "$ingot_changed" -eq 1 ]; then
  compose_apps up -d --force-recreate ingot
else
  echo "  nothing changed"
  compose_apps up -d --no-recreate ingot
fi

# Catch a service added to compose.yml and remove one deleted from it, without
# recreating either of the two above: whether they restart was decided, and
# gated, further up.
compose_apps up -d --no-recreate --remove-orphans

# --- 5. Health --------------------------------------------------------------

echo "[5/5] Health"
wait_healthy compose_apps 420

# Only now, after the deploy is known good. Recording the hashes earlier would
# make a failed deploy look like an up-to-date one on the next pass.
printf '%s\n' "$piri_config_hash" >"$FILONE_STATE_DIR/apps-piri.sha256"
printf '%s\n' "$ingot_config_hash" >"$FILONE_STATE_DIR/apps-ingot.sha256"

stamp_deploy_success apps
echo "=== apps deploy complete ==="
