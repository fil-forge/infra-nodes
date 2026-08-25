#!/usr/bin/env bash
# Bring Piri and Ingot to what the checkout says they should be.
#
# Runs on the node, as root, from the reconcile timer or by hand. Nothing here
# restarts Piri without first waiting for its proving window, because a restart
# in the wrong minute is a missed proof. A platform deploy that has something to
# apply waits on the same gate and stops both services while it works.
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

# --- 1. Render --------------------------------------------------------------

echo "[1/5] Rendering configuration and keys"

# Every read lands in its own assignment before the value is used. bao_get dies
# on a missing or empty secret, and a die inside the command substitution of a
# `mark ... write_secret_file "$(bao_get ...)"` only kills that subshell: bash
# takes the status of the outer call, and the deploy carries on and overwrites a
# valid key with nothing.
#
# The trailing newline on the PEM is deliberate: OpenBao returns the value
# without one and a PEM whose END line runs into EOF is not reliably decodable.
PIRI_IDENTITY_PEM="$(bao_get piri identity_pem)"
mark piri_changed write_secret_file "$FILONE_SECRETS_DIR/piri.pem" "$PIRI_IDENTITY_PEM
"

PIRI_OWNER_WALLET_KEY="$(bao_get piri owner_wallet_key)"
PIRI_OWNER_WALLET_HEX="$(piri_wallet_hex "$PIRI_OWNER_WALLET_KEY")"
mark piri_changed write_secret_file "$FILONE_SECRETS_DIR/piri-owner-wallet.hex" \
  "$PIRI_OWNER_WALLET_HEX"

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
INGOT_IDENTITY_PEM="$(bao_get ingot identity_pem)"
mark ingot_changed write_secret_file "$FILONE_SECRETS_DIR/ingot.pem" "$INGOT_IDENTITY_PEM
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
  die "OpenBao has no hilt-to-ingot delegation. Run store-hilt-proof.sh with the
       delegation central returned; without it every S3 request Ingot makes to
       hilt is refused."
INGOT_HILT_PROOF="$(bao_get ingot hilt_proof)"
mark ingot_changed write_secret_file "$FILONE_SECRETS_DIR/hilt-ingot-proof.txt" "$INGOT_HILT_PROOF
"

# --- 2. Pull ----------------------------------------------------------------

echo "[2/5] Pulling images"
# Before the gate, not after. Pulling can take minutes, and doing it inside the
# safe window would spend the window on a download.
compose_apps pull --quiet

mark piri_changed image_differs compose_apps piri
mark ingot_changed image_differs compose_apps ingot

# And the definition itself: an edit to node.env changes a service's environment
# or its command without changing any rendered file, and compose would recreate
# the container for it. That has to go through the gate like everything else, so
# it is detected here rather than discovered by `up -d`.
piri_config_hash="$(compose_config_hash compose_apps piri)"
ingot_config_hash="$(compose_config_hash compose_apps ingot)"
mark piri_changed config_changed apps-piri "$piri_config_hash"
mark ingot_changed config_changed apps-ingot "$ingot_config_hash"

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
config_hash_record apps-piri "$piri_config_hash"
config_hash_record apps-ingot "$ingot_config_hash"

stamp_deploy_success apps
echo "=== apps deploy complete ==="
