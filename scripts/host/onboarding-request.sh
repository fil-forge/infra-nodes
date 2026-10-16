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
# Runs after keygen.sh, which creates the identities printed here, and before
# provision-apps.sh: each Piri's first `piri init` asks the delegator for
# approval and gets a 403 for a DID that is not on its allow list.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init

bao_is_unsealed || die "OpenBao is sealed; run provision-platform.sh first"

piri_services="$(piri_services)"
# shellcheck disable=SC2206 # one service name per word
piris=($piri_services)

# Checked here rather than left to the bao_get calls below, which sit inside the
# command substitutions of a heredoc: a die in there kills only that subshell
# and the value would come out blank.
for service in "${piris[@]}"; do
  bao_has "$service" did || die "no $service DID in OpenBao; run keygen.sh"
  bao_has "$service" sprue_proof || die "no $service delegation in OpenBao; run keygen.sh"
  bao_has "$service" owner_wallet_address ||
    die "no $service owner wallet address in OpenBao; run keygen.sh"
  piri_public_url "$service" >/dev/null
done

cat <<INFO
=== onboarding request ($FILONE_NODE) ===

Send this to Forge Central. Whoever runs infra-central turns it into one
onboarding run per Piri:

INFO

for service in "${piris[@]}"; do
  cat <<INFO
  make onboard-appliance STAGE=$STAGE REGION=$REGION_LABEL \\
    PIRI_DID=$(bao_get "$service" did) \\
    PIRI_URL=$(piri_public_url "$service") \\
    PIRI_PROOF=$service-proof.txt \\
    ONBOARD_ARGS="--proof-out ingot-proof.txt"

INFO
done

cat <<INFO
Each <service>-proof.txt is that Piri's delegation below, one line, no trailing
newline. It is not a secret: a delegation names its audience, and using one
means holding that Piri's key.

Central derives this node's Ingot identity rather than taking it as an argument.
It should come out as the DID this node is configured with:

  $INGOT_DID

INFO

for service in "${piris[@]}"; do
  echo "$service-proof.txt:"
  bao_get "$service" sprue_proof
  echo
  echo
done

cat <<INFO
While central works on that, fund each Piri's owner wallet from a Calibration
faucet:

INFO
for service in "${piris[@]}"; do
  echo "  $service: $(bao_get "$service" owner_wallet_address)"
done

cat <<INFO

Each Piri registers itself in the provider registry on its first start, and that
transaction sends 5 tFIL from its wallet. Send at least 6 to each, so the 5 and
the gas both fit; an unfunded wallet makes its Piri crash-loop on "wallet
balance is too low". This is the only thing the node ever pays for. Proofs are
paid by the central signing service from PAYER_ADDRESS.

Every run above writes the same ingot-proof.txt, and that is intended. The file
holds hilt's delegation to this region's Ingot, addressed to the DID above, and
the region has one Ingot whichever Piri is being onboarded. Central issues it
once and returns it byte for byte on every later run, so each run overwrites the
file with the same content. The node needs it stored once.

INFO

# Only presence is checked: the stored delegation cannot be compared with one
# central has not returned yet.
if bao_has ingot hilt_proof; then
  cat <<INFO
OpenBao already holds a hilt delegation, which is the usual case after an app
reset or when adding a Piri. If central's run says "returning the delegation
issued earlier", there is nothing to store; start the apps:

  scripts/host/provision-apps.sh

If central issued a new delegation instead, store it first as below.

INFO
fi

cat <<INFO
ingot-proof.txt lands on your own machine, so paste the delegation into
store-hilt-proof.sh over stdin, then start the apps:

  scripts/host/store-hilt-proof.sh -
  scripts/host/provision-apps.sh

infra-central's docs/appliance-onboarding.md covers central's side of this.
INFO
