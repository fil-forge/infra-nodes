#!/usr/bin/env bash
# Open a shell on a node.
#
# There is no SSH on these boxes: no inbound port 22, no key pair, no bastion.
# Session Manager is the only way in, and it works because the SSM agent dials
# out rather than anything dialling in.
#
# Usage:
#   scripts/operator/ssm-session.sh dev
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

NODE="${1:?usage: ssm-session.sh <node>}"

require aws
require tofu

INSTANCE_ID="$(tofu_output "$NODE" instance_id)"

echo "Opening a session on node '$NODE' ($INSTANCE_ID)."
echo "The host scripts live in /opt/fil-one/infra-nodes/scripts/host and want root:"
echo "  sudo -i"
echo

# The session starts as ssm-user. Everything on the node that matters — the
# secrets tmpfs, the token files, the docker socket — is root's.
exec aws ssm start-session --target "$INSTANCE_ID"
