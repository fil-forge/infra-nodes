#!/usr/bin/env bash
# Register a node with the central services and bring back the one proof only
# central can issue.
#
# Onboarding is four things, three going one way and one coming back:
#   - the node's Piri DID onto the delegator's allow list, without which
#     `piri init` gets a 403 at the approval step
#   - `provider register <did> <url> <proof>` plus a weight against sprue,
#     without which uploads fail with CandidateUnavailable
#   - `provider add <did> us-east-9` against hilt, without which hilt refuses
#     every tenant in the region and every /s3/* invocation Ingot makes
#   - hilt's delegation to the node's Ingot DID, which hilt can only sign once
#     that DID exists, and which Ingot needs to make any of those invocations
#
# All four happen in infra-central, in a Lambda that has the credentials for
# them. This script collects what the node knows, calls it, and stores the
# returned delegation back in the node's OpenBao.
#
# Usage:
#   FILONE_ONBOARD_FUNCTION=<lambda name or arn> scripts/operator/onboard.sh dev
set -euo pipefail

# SC2154: REGION_LABEL and the two public URLs come from the node's node.env,
# sourced below.
# shellcheck disable=SC2154

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

NODE="${1:?usage: onboard.sh <node>}"

require aws
require tofu
require python3

# shellcheck disable=SC1091
. "$(node_dir "$NODE")/node.env"

if [ -z "${FILONE_ONBOARD_FUNCTION:-}" ]; then
  die "FILONE_ONBOARD_FUNCTION is not set, and there is no onboarding Lambda in
       infra-central yet. Until it lands, do the four writes by hand: docs/RUNBOOK.md,
       'Onboarding by hand', has each command and the order they go in."
fi

INSTANCE_ID="$(tofu_output "$NODE" instance_id)"

# --- What the node knows ----------------------------------------------------

# Read from the node rather than passed in, so onboarding cannot register one
# node's DID against another node's URL. The Piri delegation goes through SSM's
# command history; that is acceptable because a UCAN delegation names its
# audience, and using this one means signing as sprue.
echo "==> reading the node's identity"
request="$(ssm_run "$INSTANCE_ID" "$(
  cat <<'REMOTE'
set -euo pipefail
. /etc/filone/node.conf
cd "$FILONE_CHECKOUT"
export BAO_TOKEN="$(cat /etc/filone/bao-token)"
read_field() {
  docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e "BAO_TOKEN=$BAO_TOKEN" \
    filone-openbao bao kv get -mount=filone -field="$2" "$1"
}
python3 - "$(read_field piri did)" "$(read_field ingot did)" "$(read_field piri sprue_proof)" <<'PY'
import json, sys
print(json.dumps({
    "piri_did": sys.argv[1],
    "ingot_did": sys.argv[2],
    "piri_proof": sys.argv[3],
}))
PY
REMOTE
)")"

# Everything the Lambda needs that lives in the checkout rather than on the box.
request="$(python3 -c '
import json, sys
payload = json.loads(sys.stdin.read())
payload.update({
    "node": sys.argv[1],
    "region_label": sys.argv[2],
    "piri_url": sys.argv[3],
    "ingot_url": sys.argv[4],
})
print(json.dumps(payload))
' "$NODE" "$REGION_LABEL" "$PIRI_PUBLIC_URL" "$INGOT_PUBLIC_URL" <<<"$request")"

echo "  Piri:  $(python3 -c 'import json,sys; print(json.load(sys.stdin)["piri_did"])' <<<"$request")"
echo "  Ingot: $(python3 -c 'import json,sys; print(json.load(sys.stdin)["ingot_did"])' <<<"$request")"

# --- The three writes, and the proof back -----------------------------------

echo
echo "This registers node '$NODE' with the central dev stage:"
echo "  - allow-lists its Piri DID at the delegator"
echo "  - registers it as a provider with sprue and sets its weight"
echo "  - adds it to hilt in region $REGION_LABEL"
echo "and stores hilt's delegation to its Ingot DID on the node."
read -rp "Proceed? [y/N] " confirm
[ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || die "cancelled"

echo "==> calling $FILONE_ONBOARD_FUNCTION"
response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

aws lambda invoke \
  --function-name "$FILONE_ONBOARD_FUNCTION" \
  --cli-binary-format raw-in-base64-out \
  --payload "$request" \
  "$response_file" >/dev/null

proof="$(python3 -c '
import json, sys
response = json.load(open(sys.argv[1]))
if "errorMessage" in response:
    sys.exit("onboarding failed: " + response["errorMessage"])
proof = response.get("hilt_ingot_proof")
if not proof:
    sys.exit("onboarding returned no hilt_ingot_proof: " + json.dumps(response)[:400])
print(proof)
' "$response_file")"

echo "==> storing hilt's delegation on the node"
ssm_run "$INSTANCE_ID" "$(
  cat <<REMOTE
set -euo pipefail
export BAO_TOKEN="\$(cat /etc/filone/bao-token)"
printf '%s' '$proof' | docker exec -i \
  -e BAO_ADDR=http://127.0.0.1:8200 -e "BAO_TOKEN=\$BAO_TOKEN" \
  filone-openbao bao kv patch -mount=filone ingot hilt_proof=-
REMOTE
)" >/dev/null

echo
echo "Node '$NODE' is onboarded. Next: provision-apps.sh on the node."
