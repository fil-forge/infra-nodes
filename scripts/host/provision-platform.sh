#!/usr/bin/env bash
# Bring a new node's platform up for the first time.
#
# Interactive and run once, by an operator in an SSM session. It is the only
# script that creates secrets, and the only point at which anything is typed
# into this node by a human.
#
# Safe to re-run: OpenBao is initialised only if it is not already, and every
# secret is written only if absent, so a run that fails halfway can be repeated.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

filone_init

echo "=== provision platform ($FILONE_NODE) ==="

# --- 1. The seal token ------------------------------------------------------

# Minted at central by scripts/operator/mint-seal-token.sh, which can only run
# after the apply that allocated this node's Elastic IP, because the token is
# bound to that address.
if [ ! -r "$FILONE_SEAL_TOKEN_FILE" ]; then
  echo
  echo "This node needs its OpenBao seal token. Run scripts/operator/mint-seal-token.sh"
  echo "on a machine with credentials for the central OpenBao, then paste the token here."
  echo "It is not echoed, and it is stored 0400 root."
  read -rsp "seal token: " seal_token
  echo
  [ -n "$seal_token" ] || die "no token given"
  install -m 0400 /dev/null "$FILONE_SEAL_TOKEN_FILE"
  printf '%s\n' "$seal_token" >"$FILONE_SEAL_TOKEN_FILE"
  unset seal_token
  echo "  stored in $FILONE_SEAL_TOKEN_FILE"
else
  echo "[1/7] Seal token already present"
fi

# --- 2. OpenBao -------------------------------------------------------------

echo "[2/7] Starting OpenBao"
write_openbao_env
compose_platform up -d openbao

# An uninitialised OpenBao reports sealed, so this waits for the container to
# answer at all rather than for it to be unsealed.
for _ in $(seq 1 30); do
  docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 "$FILONE_BAO_CONTAINER" \
    bao status >/dev/null 2>&1 && break
  status=$?
  [ "$status" -eq 2 ] && break
  sleep 2
done

initialised="$(docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 "$FILONE_BAO_CONTAINER" \
  bao status -format=json 2>/dev/null | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["initialized"])' 2>/dev/null || echo unknown)"

if [ "$initialised" = "False" ]; then
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
elif [ "$initialised" = "True" ]; then
  echo "  already initialised"
else
  die "cannot tell whether OpenBao is initialised; check 'docker logs $FILONE_BAO_CONTAINER'"
fi

bao_is_unsealed || die "OpenBao is sealed. The transit key named in platform/config/openbao/bao.hcl
       has to exist on the central OpenBao, and this node's token has to be allowed to
       encrypt and decrypt with it. 'docker logs $FILONE_BAO_CONTAINER' says which of the two failed."

# --- 3. The deploy token ----------------------------------------------------

# Everything after this point, and every later deploy, runs as this token rather
# than as root. It reads and writes the node's own secrets and can do nothing
# else, so a copy of it lifted off the box is worth exactly this node's
# secrets — which are already on the box.
if [ ! -r "$FILONE_BAO_TOKEN_FILE" ]; then
  echo "[3/7] Creating the deploy token"
  echo "  paste the root token printed above (not echoed):"
  read -rsp "root token: " root_token
  echo
  [ -n "$root_token" ] || die "no root token given"

  BAO_TOKEN="$root_token"
  export BAO_TOKEN

  bao secrets enable -path="$FILONE_BAO_MOUNT" -version=2 kv >/dev/null 2>&1 ||
    echo "  kv mount $FILONE_BAO_MOUNT already enabled"

  bao policy write filone-deploy - <<POLICY >/dev/null
path "$FILONE_BAO_MOUNT/data/*" {
  capabilities = ["create", "read", "update"]
}
path "$FILONE_BAO_MOUNT/metadata/*" {
  capabilities = ["read", "list"]
}
POLICY

  # Orphan, so revoking the root token later does not take the node's deploys
  # with it. Periodic, so it renews forever; deploy-platform.sh renews it on
  # every pass, which is every five minutes.
  token="$(bao token create -policy=filone-deploy -orphan -period=72h -field=token)"
  install -m 0400 /dev/null "$FILONE_BAO_TOKEN_FILE"
  printf '%s\n' "$token" >"$FILONE_BAO_TOKEN_FILE"
  unset token root_token BAO_TOKEN
  echo "  stored in $FILONE_BAO_TOKEN_FILE"
  echo
  echo "  Store the root token in 1Password and clear it from your shell history."
  echo "  Nothing on this node holds it."
else
  echo "[3/7] Deploy token already present"
fi

# --- 4. Identity tooling ----------------------------------------------------

# ucantool and cast, pinned in the node's node.env. keygen.sh below is the only
# consumer; installing here rather than at first boot means a version bump is a
# commit and a re-run of install-tools.sh, not a replaced instance.
echo "[4/7] Installing identity tooling"
"$SCRIPT_DIR/install-tools.sh"

# --- 5. Keys and passwords --------------------------------------------------

echo "[5/7] Generating keys and passwords"
[ -x "$SCRIPT_DIR/keygen.sh" ] ||
  die "scripts/host/keygen.sh is missing or not executable in $FILONE_CHECKOUT"
"$SCRIPT_DIR/keygen.sh"

# --- 6. Operator-supplied secrets -------------------------------------------

echo "[6/7] Operator-supplied secrets"
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
prompt_secret external grafana_push_token "Grafana Cloud push token"

# --- 7. The rest of the platform --------------------------------------------

echo "[7/7] Starting Postgres, Caddy and Alloy"
"$SCRIPT_DIR/deploy-platform.sh"

echo
echo "=== platform provisioned ==="
echo "Next: scripts/operator/onboard.sh from a machine with central credentials,"
echo "then provision-apps.sh here."
