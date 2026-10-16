#!/usr/bin/env bash
# Generate this node's identities, wallet and passwords, straight into its own
# OpenBao.
#
# Run once by provision-platform.sh, and safe to run again: every secret is
# written only if it is not already there. That matters more than it sounds —
# a second run that minted a new Piri identity would leave a node whose DID is
# registered at central and whose key no longer matches it.
#
# No private key ever leaves this box, and none is written to a disk that
# survives a reboot. The one file that has to exist on disk, the PEM the
# delegation is signed with, is written into the secrets tmpfs and removed on
# the way out.
set -euo pipefail

# SC2154: SPRUE_DID comes from the node's node.env, which filone_init sources
# at run time.
# shellcheck disable=SC2154

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init

WORK_DIR="$(mktemp -d "$FILONE_SECRETS_DIR/.keygen.XXXXXX")"
chmod 0700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== keygen ($FILONE_NODE) ==="

command -v ucantool >/dev/null || die "ucantool is not on PATH; run scripts/host/install-tools.sh"
command -v cast >/dev/null || die "cast is not on PATH; run scripts/host/install-tools.sh"

# --- Identities -------------------------------------------------------------

# Both DIDs printed here are did:keys, and Piri's is the one it uses. Ingot
# signs as the did:web in node.env instead, and this key is what its DID
# document publishes; the other host scripts print the pair.
#
# ucantool prints the PEM on stdout and the DID on stderr. The DID goes into
# OpenBao in the same write as the key, and every later run reads it rather than
# deriving it. ucantool v0.1.0 gained `identity inspect`, which
# prints the DID of an existing PEM; switching to it would let the DID be
# derived on demand instead of stored.
generate_identity() {
  local name="$1"
  # Separate declarations: bash expands all of `local`'s arguments before it
  # assigns any of them, so $name on this line would be the caller's value
  # rather than the one just set, and both paths would come out as
  # "$WORK_DIR/.pem".
  local pem_file="$WORK_DIR/$name.pem"
  local did_file="$WORK_DIR/$name.did"
  local did

  if bao_has "$name" identity_pem; then
    bao_has "$name" did ||
      die "$name has a key in OpenBao but no DID beside it. Derive it — read the PEM from OpenBao
       and pipe it to 'ucantool identity inspect' — and write it to $FILONE_BAO_MOUNT/$name#did."
    echo "  $name identity already generated ($(bao_get "$name" did))"
    return 0
  fi

  ucantool identity generate >"$pem_file" 2>"$did_file"
  did="$(grep -oE 'did:key:z[a-zA-Z0-9]+' "$did_file")" ||
    die "ucantool identity generate printed no DID"

  bao_put_if_absent "$name" identity_pem "$(cat "$pem_file")" did "$did"
  echo "  $name identity: $did"
}

piri_services="$(piri_services)"
# shellcheck disable=SC2206 # one service name per word
piris=($piri_services)

# A node moving from one Piri to several keeps that Piri as piri-0: same key,
# same DID, same funded wallet, so central needs no new identity for it. Copied
# rather than moved, in one write, so the old path stays readable until someone
# deletes it. Values go through a pipe, never an argument.
adopt_single_piri() {
  [ "${piris[0]}" = piri-0 ] || return 0
  bao_path_exists piri || return 0
  if bao_path_exists piri-0; then
    echo "  piri-0 already in OpenBao ($(bao_get piri-0 did)); leaving piri alone"
    return 0
  fi
  bao kv get -mount="$FILONE_BAO_MOUNT" -format=json piri |
    jq -c '.data.data' |
    bao kv put -mount="$FILONE_BAO_MOUNT" piri-0 - >/dev/null ||
    die "could not copy $FILONE_BAO_MOUNT/piri to $FILONE_BAO_MOUNT/piri-0"
  echo "  copied piri to piri-0 ($(bao_get piri-0 did))"
}

echo "[1/4] Identities"
adopt_single_piri
for service in "${piris[@]}"; do
  generate_identity "$service"
done
generate_identity ingot

# --- The Piri delegation to sprue ------------------------------------------

# Signed by Piri's own key, so central cannot issue it: this is the half of
# onboarding that has to originate on the node. Onboarding hands it to sprue as
# the third argument of `provider register`.
#
# The audience travels with the proof. A delegation's audience is fixed at
# issue time, so a node.env change to SPRUE_DID does not reach a proof already
# sitting in OpenBao; without a recorded audience to compare against, a stale
# proof would look "already issued" forever while every call it backs is
# addressed to a DID sprue no longer answers to.
echo "[2/4] Piri delegations to sprue"
issue_sprue_proof() {
  local service="$1" pem proof

  if bao_has "$service" sprue_proof && bao_has "$service" sprue_proof_audience &&
    [ "$(bao_get "$service" sprue_proof_audience)" = "$SPRUE_DID" ]; then
    echo "  $service: already issued"
    return 0
  fi

  if bao_has "$service" sprue_proof; then
    echo "  $service: stored delegation predates SPRUE_DID=$SPRUE_DID; reissuing"
  fi

  pem="$WORK_DIR/$service-signing.pem"
  install -m 0600 /dev/null "$pem"
  # The trailing newline matters: a PEM whose END line runs into EOF is not
  # reliably decodable, and OpenBao returns the value without one.
  { bao_get "$service" identity_pem; echo; } >"$pem"

  # No expiration: the delegation authorises Piri's ongoing relationship with
  # sprue, and one that expires takes the node's uploads down at a moment
  # nobody chose. Revocation is by removing the provider at sprue.
  proof="$(ucantool delegate \
    --issuer-private-key-file="$pem" \
    --audience="$SPRUE_DID" \
    --command=/blob/allocate \
    --command=/blob/accept \
    --command=/blob/replica/allocate \
    --command=/pdp/info \
    --container=base64+gzip)"

  rm -f "$pem"
  bao_replace_fields "$service" sprue_proof "$proof" sprue_proof_audience "$SPRUE_DID"
  echo "  $service: issued"
}

for service in "${piris[@]}"; do
  issue_sprue_proof "$service"
done

# --- The owner wallets ------------------------------------------------------

# The EVM account a Piri registers as its owner on-chain. Registration sends 5
# tFIL from it to the provider registry, so each wallet has to be funded before
# its Piri's first start; docs/RUNBOOK.md step 5 says how much and from where.
# Nothing after registration spends from it, because the central signing service
# pays for proofs, but it stays the identity the registry records, so losing it
# means re-registering.
#
# One wallet per Piri. The registry allows one provider per address, and Piris
# sending from one address would race each other for nonces.
echo "[3/4] Owner wallets"
generate_owner_wallet() {
  local service="$1" wallet address private_key

  if bao_has "$service" owner_wallet_key; then
    bao_has "$service" owner_wallet_address ||
      die "$service has an owner wallet key in OpenBao but no address beside it. Derive it — read
       the key from OpenBao and pipe it to 'cast wallet address' — and write it to
       $FILONE_BAO_MOUNT/$service#owner_wallet_address."
    echo "  $service: already generated ($(bao_get "$service" owner_wallet_address))"
    return 0
  fi

  wallet="$(cast wallet new)"
  address="$(printf '%s\n' "$wallet" | awk '/^Address:/ { print $2 }')"
  # Stored as 64 bare hex characters, without cast's 0x. Piri's --wallet-file
  # wants this key wrapped in hex-encoded Filecoin keystore JSON, and the
  # signing service wants it bare; keeping the bare form here means the wrapping
  # happens where it is needed rather than being undone twice.
  private_key="$(printf '%s\n' "$wallet" | awk '/^Private key:/ { print $3 }' | sed 's/^0x//')"
  unset wallet

  if [ -z "$address" ] || [ -z "$private_key" ]; then
    die "could not parse 'cast wallet new' output"
  fi

  bao_put_if_absent "$service" owner_wallet_key "$private_key" owner_wallet_address "$address"
  unset private_key
  echo "  $service: generated $address"
}

for service in "${piris[@]}"; do
  generate_owner_wallet "$service"
done

# --- Passwords --------------------------------------------------------------

# Hex, all of them. postgres-init interpolates these into SQL string literals,
# which is safe exactly because a hex string contains no quote to escape.
echo "[4/4] Passwords"
generate_password() {
  local path="$1" field="$2"
  if bao_has "$path" "$field"; then
    echo "  $path#$field already set"
    return 0
  fi
  bao_put_if_absent "$path" "$field" "$(openssl rand -hex 32)"
}

generate_password postgres admin_password
generate_password postgres piri_password
generate_password postgres ingot_password

echo "=== keygen complete ==="
