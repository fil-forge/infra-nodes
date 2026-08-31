#!/usr/bin/env bash
# Give this node the region key Ingot wraps every object's content-encryption
# key under, and the token it reads that key with.
#
# Bucket encryption is not optional: Ingot refuses to start without a region key
# provider, and with a wrong one it starts, answers /health and fails on the
# first object write. So this runs before the apps deploy that first names the
# key, by an operator in an SSM session.
#
# It needs the root token, because enabling a secrets engine and writing a
# policy are both outside what the deploy token is granted.
#
# Safe to re-run. The transit mount, the key and the policy are created only if
# absent; the token is minted every time, because this is also the rotation
# path and a re-run after a revocation has to replace the dead one.
#
# Usage:
#   scripts/host/provision-regionkey.sh
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init

bao_is_unsealed || die "OpenBao is sealed; run provision-platform.sh first"

echo "=== provision region key ($FILONE_NODE) ==="
echo "  key: $FILONE_REGIONKEY_NAME in the transit engine of this node's OpenBao"
echo
echo "  Paste the root token printed when this node's OpenBao was initialised."
echo "  It is in 1Password and is not echoed here."
read -rsp "root token: " root_token
echo
[ -n "$root_token" ] || die "no root token given"

BAO_TOKEN="$root_token"
export BAO_TOKEN
unset root_token

provision_regionkey

echo
echo "=== region key provisioned ==="
echo "Next: deploy-platform.sh, which starts OpenBao's unix listener, then"
echo "deploy-apps.sh, which renders the token into Ingot's config."
