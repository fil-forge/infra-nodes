#!/usr/bin/env bash
# Mint the token a node's OpenBao unseals with, against the central OpenBao.
#
# Run once per node, after the apply that allocates its Elastic IP: the token is
# bound to that address, so it cannot exist before the address does.
#
# The token is printed once, to this terminal. Paste it into
# provision-platform.sh on the node, which stores it 0400 root. Nothing writes
# it to disk here.
#
# Usage:
#   BAO_TOKEN=<a central token that can write policies and create tokens> \
#     scripts/operator/mint-seal-token.sh dev
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

NODE="${1:?usage: mint-seal-token.sh <node>}"

require aws
require curl
require tofu
require python3

: "${BAO_TOKEN:?BAO_TOKEN must hold a central OpenBao token allowed to write sys/policies and create tokens}"

CENTRAL_ADDR="$(bao_hcl_seal_value "$NODE" address)"
KEY_NAME="$(bao_hcl_seal_value "$NODE" key_name)"
MOUNT_PATH="$(bao_hcl_seal_value "$NODE" mount_path)"
NODE_IP="$(tofu_output "$NODE" public_ip)"
POLICY_NAME="appliance-$NODE-unseal"
ROLE_NAME="appliance-$NODE-unseal"

echo "Central:  $CENTRAL_ADDR"
echo "Key:      $MOUNT_PATH/keys/$KEY_NAME"
echo "Node IP:  $NODE_IP"
echo

central_api() {
  local method="$1" path="$2" body="${3:-}" response status
  if [ -n "$body" ]; then
    response="$(curl -sS --max-time 30 -w '\n%{http_code}' \
      --header "X-Vault-Token: $BAO_TOKEN" \
      --request "$method" --data "$body" "$CENTRAL_ADDR/v1/$path")"
  else
    response="$(curl -sS --max-time 30 -w '\n%{http_code}' \
      --header "X-Vault-Token: $BAO_TOKEN" \
      --request "$method" "$CENTRAL_ADDR/v1/$path")"
  fi

  status="$(printf '%s' "$response" | tail -1)"
  case "$status" in
    200 | 204) printf '%s' "$response" | sed '$d' ;;
    *) die "$method $path returned HTTP $status: $(printf '%s' "$response" | sed '$d')" ;;
  esac
}

# The key has to exist before a policy can usefully name it. Creating it here
# rather than assuming it does means one fewer step to forget, and it is a no-op
# if it is already there.
echo "==> ensuring the transit key exists"
central_api POST "$MOUNT_PATH/keys/$KEY_NAME" '{"type":"aes256-gcm96"}' >/dev/null

# Encrypt and decrypt on this node's key, and nothing else. A token lifted off
# this node unseals this node; it reads no secret at central and touches no
# other node's key.
echo "==> writing policy $POLICY_NAME"
read -r -d '' policy_rules <<POLICY || true
path "$MOUNT_PATH/encrypt/$KEY_NAME" {
  capabilities = ["update"]
}
path "$MOUNT_PATH/decrypt/$KEY_NAME" {
  capabilities = ["update"]
}
POLICY

policy="$(python3 -c 'import json,sys; print(json.dumps({"policy": sys.stdin.read()}))' \
  <<<"$policy_rules")"
central_api PUT "sys/policies/acl/$POLICY_NAME" "$policy" >/dev/null

# The token comes from a role rather than from a bare create, and that is not a
# stylistic choice: auth/token/create takes CIDRs only from a role or from the
# parent token it inherits from. Passing bound_cidrs in the request body is
# ignored without complaint, and an orphan token has no parent to inherit from
# either — so a bare create would mint an unrestricted token while looking like
# it had done the right thing.
#
# Orphan, so revoking the operator token that created it does not take the node
# down with it. Periodic, so it renews forever rather than expiring on a date
# nobody is watching. CIDR-bound, so it is worthless anywhere but this node.
echo "==> writing token role $ROLE_NAME"
role_request="$(python3 -c '
import json, sys
print(json.dumps({
    "allowed_policies": [sys.argv[1]],
    "orphan": True,
    "renewable": True,
    "token_period": "720h",
    "token_bound_cidrs": [sys.argv[2] + "/32"],
}))
' "$POLICY_NAME" "$NODE_IP")"
central_api POST "auth/token/roles/$ROLE_NAME" "$role_request" >/dev/null

echo "==> creating the token"
token_request="$(python3 -c '
import json, sys
print(json.dumps({
    "policies": [sys.argv[1]],
    "display_name": "appliance-" + sys.argv[2] + "-unseal",
}))
' "$POLICY_NAME" "$NODE")"

token_response="$(central_api POST "auth/token/create/$ROLE_NAME" "$token_request")"
token="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])' \
  <<<"$token_response")"

# The one property worth checking rather than assuming, because getting it wrong
# is silent: a token that is not CIDR-bound works everywhere, including from
# wherever it eventually leaks to.
bound="$(python3 -c '
import json, sys
auth = json.load(sys.stdin)["auth"]
print(",".join(auth.get("bound_cidrs") or []))
' <<<"$token_response")"
[ -n "$bound" ] || die "central returned a token with no CIDR binding. Check that
       auth/token/roles/$ROLE_NAME carries token_bound_cidrs, and revoke the token
       that was just created."
echo "  bound to $bound"

echo
echo "Seal token for node '$NODE'. It is printed once and stored nowhere here."
echo "Paste it when provision-platform.sh asks:"
echo
echo "  $token"
echo
echo "Revoking it at central and restarting the node's OpenBao is the kill lever."
