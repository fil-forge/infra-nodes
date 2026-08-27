#!/usr/bin/env bash
# Print what Forge Central needs to register this node.
#
# Onboarding is a conversation between two sides with no shared credentials. The
# node operator has root here and nothing at central; central holds the
# delegator, sprue and hilt and cannot read this node's keys. This script
# collects the node's half of it. Central runs `make onboard-appliance` with what
# it prints and returns hilt's delegation to this node's Ingot, which
# store-hilt-proof.sh installs.
#
# The Ingot identity is not in here. Central derives it from the region label as
# a did:web under the stage's domain, so there is nothing to send and nothing to
# mistype, and the DID document publishes whichever key the node currently
# holds. infra-central's docs/appliance-onboarding.md is where that is decided.
#
# Runs after keygen.sh, which creates the identity printed here, and before
# provision-apps.sh: Piri's first `piri init` asks the delegator for approval and
# gets a 403 for a DID that is not on its allow list.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init

bao_is_unsealed || die "OpenBao is sealed; run provision-platform.sh first"

bao_has piri did || die "no Piri DID in OpenBao; run keygen.sh"
bao_has piri sprue_proof || die "no Piri delegation in OpenBao; run keygen.sh"

cat <<INFO
=== onboarding request ($FILONE_NODE) ===

Send this to Forge Central. Whoever runs infra-central turns it into:

  make onboard-appliance STAGE=$STAGE REGION=$REGION_LABEL \\
    PIRI_DID=$(bao_get piri did) \\
    PIRI_URL=$PIRI_PUBLIC_URL \\
    PIRI_PROOF=piri-proof.txt \\
    ONBOARD_ARGS="--proof-out ingot-proof.txt"

piri-proof.txt is the delegation below, one line, no trailing newline. It is not
a secret: a delegation names its audience, and using this one means holding
this node's Piri key.

INFO

bao_get piri sprue_proof
echo

cat <<'INFO'

Central runs that command and sends back ingot-proof.txt, hilt's delegation to
this node's Ingot. Install the delegation, then start the apps:

  scripts/host/store-hilt-proof.sh ingot-proof.txt
  scripts/host/provision-apps.sh

infra-central's docs/appliance-onboarding.md covers central's side of this.
INFO
