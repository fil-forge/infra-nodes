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

# Central mints this token wrapped, so an operator carries a single-use wrapping
# token here and the seal token itself stays inside the central OpenBao until
# this node claims it below. Nothing but this exchange ever sees the credential,
# and because the exchange can happen once, a token central refuses is one that
# has already been spent, whether by somebody else or by a run of this script
# that broke off before it stored anything.
#
# Minting waits on the apply that allocated this node's Elastic IP, because the
# token central mints is bound to that address.
if [ ! -r "$FILONE_SEAL_TOKEN_FILE" ]; then
  central="$(central_seal_addr)"
  echo "[1/7] Claiming the seal token from $central"
  echo
  echo "  Central runs 'make mint-appliance-token' in infra-central and hands back a"
  echo "  wrapping token. Paste it here; it is not echoed. Exchanging it spends it, and"
  echo "  what comes back is stored 0400 root."
  read -rsp "wrapping token: " wrapping_token
  echo
  [ -n "$wrapping_token" ] || die "no wrapping token given"

  # curl puts --header values in its own argv, where anything on the host that
  # can read /proc can take the token while the request is in flight, so the
  # header goes in on stdin. printf is a shell builtin and never gets an argv of
  # its own. The exit code is kept because it is what says whether the request
  # ever left, which an `if !` would collapse to 1.
  curl_status=0
  response="$(printf 'X-Vault-Token: %s\n' "$wrapping_token" |
    curl -sS --max-time 30 -w '\n%{http_code}' --header @- \
      --request POST "$central/v1/sys/wrapping/unwrap")" || curl_status=$?
  unset wrapping_token

  case "$curl_status" in
    0) ;;
    6 | 7)
      die "could not reach the central OpenBao at $central (curl $curl_status).
       Nothing left this node, so the wrapping token is unspent: fix the route to
       central and re-run with the same token." ;;
    *)
      die "the exchange with $central broke off mid-flight (curl $curl_status), so
       whether central spent the wrapping token is unknown, and so is whether the
       seal token it unwrapped went anywhere. Do not paste this token again: if it
       was spent, the next attempt is refused and that refusal says nothing about
       who spent it. Re-mint at central with TOKEN_ARGS=--reissue, which revokes
       this one, and claim the token that comes back." ;;
  esac

  status="$(printf '%s' "$response" | tail -1)"
  # On a 200 this holds the seal token, so it is printed only on a failure.
  body="$(printf '%s' "$response" | sed '$d')"
  unset response

  case "$status" in
    200) ;;
    400 | 403 | 404)
      die "central refused the wrapping token (HTTP $status): $body
       A wrapping token can be spent once and expires 24 hours after it is minted,
       so this is a token that has already been exchanged or one that has run out.
       An earlier run of this script that broke off mid-flight spends it the same
       way; failing that, somebody who could read the channel it was delivered on
       spent it. Either way this is not a retry: re-mint at central with
       TOKEN_ARGS=--reissue, which revokes this one." ;;
    *)
      die "claiming the seal token failed with HTTP $status: $body" ;;
  esac

  # Assert the one path the credential comes back on rather than searching for
  # it. A response shaped any other way is worth stopping on: the alternative is
  # storing an empty file and finding out at the unseal three steps later.
  seal_token="$(printf '%s' "$body" | python3 -c '
import json, sys

token = (json.load(sys.stdin).get("auth") or {}).get("client_token")
if not token:
    sys.exit("the unwrapped response carries no auth.client_token")
print(token)
')" || die "central returned something other than a wrapped token; nothing was stored"
  unset body

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
  capabilities = ["create", "read", "update", "patch"]
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
echo "Next: onboarding-request.sh, send what it prints to Forge Central, and"
echo "store-hilt-proof.sh with the delegation they return. Then provision-apps.sh."
