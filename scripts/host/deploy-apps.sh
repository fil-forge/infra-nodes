#!/usr/bin/env bash
# Bring the Piris and Ingot to what the checkout says they should be.
#
# Runs on the node, as root, from the reconcile timer or by hand. Nothing here
# restarts a Piri without first waiting for its proving window, because a
# restart in the wrong minute is a missed proof. The Piris restart one at a
# time, each behind its own gate, so the others keep serving meanwhile. A platform deploy that has something to
# apply waits on the same gate and stops both services while it works.
#
# Idempotent. A run that changes nothing renders identical files, finds the
# running images already correct, restarts nothing and never touches the gate.
set -euo pipefail

# SC2154: PAYER_ADDRESS comes from the node's node.env, which filone_init
# sources at run time.
# shellcheck disable=SC2154

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

filone_init

# Reconcile resets the checkout under whatever is running, so a hand-started
# deploy waits for it rather than reading half of one revision and half of the
# next. A deploy reconcile started itself already holds this.
take_deploy_lock

echo "=== deploy apps ($FILONE_NODE) ==="

bao_is_unsealed || die "OpenBao is sealed; run deploy-platform.sh first"

[ "$PAYER_ADDRESS" != "0x0000000000000000000000000000000000000000" ] ||
  die "PAYER_ADDRESS in nodes/$FILONE_NODE/node.env is still the placeholder.
       Read the real address from the central dev stage (docs/RUNBOOK.md says how) and commit it."

piri_services="$(piri_services)"
# shellcheck disable=SC2206 # one service name per word
piris=($piri_services)
declare -A piri_changed
for service in "${piris[@]}"; do piri_changed[$service]=0; done
# A change every Piri sees: the base config and the env file they share.
piris_changed=0
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
for service in "${piris[@]}"; do
  changed=0
  identity_pem="$(bao_get "$service" identity_pem)"
  mark changed write_secret_file "$FILONE_SECRETS_DIR/$service.pem" "$identity_pem
"

  owner_wallet_key="$(bao_get "$service" owner_wallet_key)"
  owner_wallet_hex="$(piri_wallet_hex "$owner_wallet_key")"
  mark changed write_secret_file "$FILONE_SECRETS_DIR/$service-owner-wallet.hex" \
    "$owner_wallet_hex"
  piri_changed[$service]="$changed"
done
unset identity_pem owner_wallet_key owner_wallet_hex

# Piri's base config carries no secret, only addresses and URLs from node.env.
# Every Piri on the node reads the same one.
mark piris_changed render_template \
  "$FILONE_NODE_DIR/apps/config/piri/piri-base-config.toml.tpl" \
  "$FILONE_SECRETS_DIR/piri-base-config.toml"

PIRI_POSTGRES_PASSWORD="$(bao_get postgres piri_password)"
export PIRI_POSTGRES_PASSWORD
# A local Lotus can deliberately allow unauthenticated RPC. In that case the
# node declares LOTUS_RPC_AUTH_REQUIRED=false and no token is read or rendered.
if [ "${LOTUS_RPC_AUTH_REQUIRED:-true}" = true ]; then
  CHAIN_RPC_TOKEN="$(bao_get external chain_rpc_token)"
  export CHAIN_RPC_TOKEN
else
  unset CHAIN_RPC_TOKEN
fi
mark piris_changed render_template \
  "$FILONE_NODE_DIR/apps/templates/apps.env.tpl" \
  "$FILONE_SECRETS_DIR/apps.env"

# Ingot's identity, its config (which embeds the DSN and the region-key token)
# and hilt's delegation to it.
INGOT_IDENTITY_PEM="$(bao_get ingot identity_pem)"
mark ingot_changed write_secret_file "$FILONE_SECRETS_DIR/ingot.pem" "$INGOT_IDENTITY_PEM
"

INGOT_POSTGRES_PASSWORD="$(bao_get postgres ingot_password)"
# The token Ingot wraps object keys with, minted by provision-regionkey.sh.
# bao_get dies when it is absent, which is the right answer: Ingot rendered
# without it starts, answers /health and fails on the first object write.
INGOT_REGIONKEY_TOKEN="$(bao_get ingot regionkey_token)"
export INGOT_POSTGRES_PASSWORD INGOT_REGIONKEY_TOKEN FILONE_REGIONKEY_NAME
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

mark ingot_changed image_differs compose_apps ingot

# And the definition itself: an edit to node.env changes a service's environment
# or its command without changing any rendered file, and compose would recreate
# the container for it. That has to go through the gate like everything else, so
# it is detected here rather than discovered by `up -d`.
declare -A piri_config_hash
for service in "${piris[@]}"; do
  changed="${piri_changed[$service]}"
  [ "$piris_changed" -eq 0 ] || changed=1
  mark changed image_differs compose_apps "$service"
  piri_config_hash[$service]="$(compose_config_hash compose_apps "$service")"
  mark changed config_changed "apps-$service" "${piri_config_hash[$service]}"
  piri_changed[$service]="$changed"
done
ingot_config_hash="$(compose_config_hash compose_apps ingot)"
mark ingot_changed config_changed apps-ingot "$ingot_config_hash"

# --- 3. Piri ----------------------------------------------------------------

echo "[3/5] Piri"
for service in "${piris[@]}"; do
  if [ "${piri_changed[$service]}" -eq 1 ]; then
    echo "  $service: something changed; waiting for a safe restart window"
    "$SCRIPT_DIR/pdp-gate.sh" "$service"
    # --force-recreate because most of what changes here is the *content* of a
    # bind-mounted file — a re-rendered config, a rotated password, a new proof.
    # Compose decides recreation from the service definition, which those leave
    # untouched, so a plain `up -d` would report success and leave the old
    # process running with the old secret.
    #
    # --no-deps because --force-recreate reaches the services this one depends
    # on, and each Piri depends on the one before it: recreating piri-2 would
    # recreate piri-0 and piri-1 too, past their own gates.
    compose_apps up -d --force-recreate --no-deps "$service"
    # Healthy before the next one goes down, so a bad image stops the rollout at
    # the first Piri instead of taking all of them out.
    wait_healthy compose_apps 420
  else
    echo "  $service: nothing changed"
    # Without --no-deps: a Piri created for the first time waits here for the
    # one before it to be healthy, as compose.yml asks.
    compose_apps up -d --no-recreate "$service"
  fi
done

# --- 4. Ingot ---------------------------------------------------------------

# After the Piris: Ingot writes through to them, and starting against a Piri that is
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
for service in "${piris[@]}"; do
  config_hash_record "apps-$service" "${piri_config_hash[$service]}"
done
config_hash_record apps-ingot "$ingot_config_hash"

stamp_deploy_success apps
echo "=== apps deploy complete ==="
