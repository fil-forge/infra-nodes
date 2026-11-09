#!/usr/bin/env bash
# Give this node a new host token: the OpenBao token every deploy, reconcile
# pass and snapshot runs as, under the filone-host policy.
#
# provision-platform.sh mints one on a new node. Run this by hand, by an
# operator in an SSM session, on a node that holds a token from before the
# policy covered snapshots (its policy is filone-deploy, and the snapshot job
# says so), to rotate the token, or after a restore from a snapshot older than
# the token's 72-hour period.
#
# It needs the root token, because writing a policy and minting an orphan token
# are both outside what the host token is granted.
#
# Safe to re-run. The new token replaces the old one in /etc/fil-one/bao-token
# before the old one is revoked, and the filone-deploy policy is deleted.
#
# Usage:
#   scripts/host/provision-host-token.sh
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

case "${1:-}" in
  "") ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0 ;;
  *) die "unknown option: $1" ;;
esac

filone_init

bao_is_unsealed || die "OpenBao is sealed; run provision-platform.sh first"

echo "=== provision host token ($FILONE_NODE) ==="
echo
echo "  Paste the root token printed when this node's OpenBao was initialised."
echo "  It is in 1Password and is not echoed here."
read -rsp "root token: " root_token
echo
[ -n "$root_token" ] || die "no root token given"

BAO_TOKEN="$root_token"
export BAO_TOKEN
unset root_token

take_deploy_lock
provision_host_token
unset BAO_TOKEN

# Back under the new host token, which is what renews and what the snapshot job
# reads with. The renewal proves the file holds a token OpenBao accepts.
renew_bao_token
request_openbao_snapshot

echo
echo "=== host token provisioned ==="
