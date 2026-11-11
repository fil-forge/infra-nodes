#!/usr/bin/env bash
# Bring a new node's platform up for the first time.
#
# Interactive and run once, by an operator in an SSM session. It and
# provision-backups.sh, which it calls, are the only scripts that create
# secrets, and the only points at which anything is typed into this node by a
# human.
#
# Safe to re-run: OpenBao is initialised only if it is not already, and every
# secret is written only if absent, so a run that fails halfway can be repeated.
# The one exception is Ingot's region-key token in step 5, which is minted on
# every run because that step is also the rotation path. A re-run therefore ends
# with a token the running Ingot does not hold yet; the next apps deploy renders
# it, and the old one stays valid until its period lapses.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

filone_init

echo "=== provision platform ($FILONE_NODE) ==="

# --- 1. The seal token ------------------------------------------------------

# Minting waits on the apply that allocated this node's Elastic IP, because the
# token central mints is bound to that address.
if [ ! -r "$FILONE_SEAL_TOKEN_FILE" ]; then
  central="$(central_seal_addr)"
  echo "[1/9] Claiming the seal token from $central"
  echo
  echo "  Central runs 'make mint-appliance-credentials' in infra-central and hands back an"
  echo "  unseal-token wrapping token and, on a node that takes backups, a backup-key"
  echo "  wrapping token, which step 4 asks for. Paste the unseal-token wrapping token"
  echo "  here; it is not echoed. Exchanging it spends it, and what comes back is stored"
  echo "  0400 root."
  claim_seal_token
else
  echo "[1/9] Seal token already present"
fi

# --- 2. OpenBao -------------------------------------------------------------

echo "[2/9] Starting OpenBao"
start_openbao

if bao_is_initialised; then
  echo "  already initialised"
else
  echo
  echo "  Initialising OpenBao. The recovery key and the root token below are printed"
  echo "  once and are not stored on this node. Put both in 1Password before continuing:"
  echo "  losing the recovery key means the only way back into this OpenBao is to rebuild"
  echo "  the node and re-onboard it."
  echo
  # One recovery share. A transit-sealed OpenBao unseals without them, so these
  # exist only to regenerate a root token, and splitting that across several
  # operators buys nothing for a dev node.
  docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 "$FILONE_BAO_CONTAINER" \
    bao operator init -recovery-shares=1 -recovery-threshold=1
  echo
fi

bao_is_unsealed || die "OpenBao is sealed. The transit key named in platform/config/openbao/bao.hcl
       has to exist on the central OpenBao, and this node's token has to be allowed to
       encrypt and decrypt with it. 'docker logs $FILONE_BAO_CONTAINER' says which of the two failed."

# --- 3. The host token ------------------------------------------------------

# Everything after this point, and every later deploy, reconcile pass and
# snapshot, runs as this token rather than as root. It reads and writes the
# node's own secrets and reads raft snapshots, and can do nothing else, so a copy
# of it lifted off the box is worth exactly this node's secrets, which are
# already on the box. provision_host_token in lib/openbao.sh writes the policy.
if [ ! -r "$FILONE_BAO_TOKEN_FILE" ]; then
  echo "[3/9] Creating the host token"
  echo "  paste the root token printed above (not echoed):"
  read -rsp "root token: " root_token
  echo
  [ -n "$root_token" ] || die "no root token given"

  BAO_TOKEN="$root_token"
  export BAO_TOKEN
  unset root_token

  provision_host_token
  unset BAO_TOKEN
  echo
  echo "  Store the root token in 1Password and clear it from your shell history."
  echo "  Nothing on this node holds it."
else
  echo "[3/9] Host token already present"
fi

# --- 4. The backup key ------------------------------------------------------

# The access key this node writes its Postgres and OpenBao backups with, stored
# in OpenBao with the target it writes to, then checks that it can write there.
# It runs as the host token step 3 just created, enables the daily OpenBao
# snapshot once the key has written to the target, and does nothing on a node
# whose node.env sets FILONE_TAKES_BACKUPS=false. The secrets the steps below
# write are snapshotted after step 9, when deploy-platform.sh finishes.
echo "[4/9] Storing the backup key"
"$SCRIPT_DIR/provision-backups.sh"

# --- 5. The region key ------------------------------------------------------

# Ingot wraps every object's content-encryption key under this one, in this
# node's own transit engine, and refuses to start without it. Next to the
# host token because it needs the same root token: enabling a secrets engine
# and writing a policy are both outside what the host token is granted.
echo "[5/9] Creating the region key"
echo "  paste the root token again (not echoed):"
read -rsp "root token: " root_token
echo
[ -n "$root_token" ] || die "no root token given"
BAO_TOKEN="$root_token"
export BAO_TOKEN
unset root_token

provision_regionkey
unset BAO_TOKEN

# --- 6. Identity tooling ----------------------------------------------------

# ucantool and cast, pinned in the node's node.env. keygen.sh below is the only
# consumer; installing here rather than at first boot means a version bump is a
# commit and a re-run of install-tools.sh, not a replaced instance.
echo "[6/9] Installing identity tooling"
"$SCRIPT_DIR/install-tools.sh"

# --- 7. Keys and passwords --------------------------------------------------

echo "[7/9] Generating keys and passwords"
[ -x "$SCRIPT_DIR/keygen.sh" ] ||
  die "scripts/host/keygen.sh is missing or not executable in $FILONE_CHECKOUT"
"$SCRIPT_DIR/keygen.sh"

# --- 8. Operator-supplied secrets -------------------------------------------

echo "[8/9] Operator-supplied secrets"
prompt_secret() {
  local path="$1" field="$2" description="$3" value
  if bao_has "$path" "$field"; then
    echo "  $description already stored"
    return 0
  fi
  read -rsp "  $description: " value
  echo
  [ -n "$value" ] || die "no value given for $description"
  bao_put_if_absent "$path" "$field" "$value"
}

prompt_secret external chain_rpc_token "chain.love access token"

if node_ships_telemetry; then
  prompt_secret external grafana_push_token "Grafana Cloud push token"
else
  echo "  node.env names no Grafana endpoints, so no push token is needed"
fi

# --- 9. The rest of the platform --------------------------------------------

# Which of them this node runs. The staging appliance has the host's Caddy and
# the host's Alloy, so there it is Postgres alone.
starting="Postgres"
if [ "${FILONE_HOST_CADDY:-false}" != true ]; then
  starting="$starting, Caddy"
fi
if node_ships_telemetry; then
  starting="$starting and Alloy"
fi
echo "[9/9] Starting $starting"
"$SCRIPT_DIR/deploy-platform.sh"

echo
echo "=== platform provisioned ==="
echo "Next: onboarding-request.sh, send what it prints to Forge Central, and"
echo "store-hilt-proof.sh with the delegation they return. Then provision-apps.sh."
