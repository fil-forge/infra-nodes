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
# The Ingot identity is not sent, only shown. Central derives the same did:web
# from the stage's domain, so there is nothing to mistype, and the DID document
# this node serves publishes whichever key it currently holds. It is printed
# below because it is the one string both sides have to agree on, and a
# mismatch is invisible until Ingot's first S3 call is refused.
# infra-central's docs/appliance-onboarding.md is where that is decided.
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
# Checked here rather than left to the bao_get below it, which sits inside the
# command substitution of a heredoc: a die in there kills only that subshell and
# the address would come out blank.
bao_has piri owner_wallet_address ||
  die "no Piri owner wallet address in OpenBao; run keygen.sh"

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

Central derives this node's Ingot identity rather than taking it as an argument.
It should come out as the DID this node is configured with:

  $INGOT_DID

INFO

bao_get piri sprue_proof
echo

cat <<INFO

While central works on that, fund this node's owner wallet from a Calibration
faucet:

  $(bao_get piri owner_wallet_address)

Piri registers itself in the provider registry on its first start, and that
transaction sends 5 tFIL from this wallet. Send at least 6, so the 5 and the gas
both fit; an unfunded wallet makes Piri crash-loop on "wallet balance is too
low". This is the only thing the node ever pays for. Proofs are paid by the
central signing service from PAYER_ADDRESS.

Central sends back ingot-proof.txt, hilt's delegation to this node's Ingot,
addressed to the DID above. The file lands on your own machine, so paste the
delegation into store-hilt-proof.sh over stdin, then start the apps:

  scripts/host/store-hilt-proof.sh -
  scripts/host/provision-apps.sh

infra-central's docs/appliance-onboarding.md covers central's side of this.
INFO
