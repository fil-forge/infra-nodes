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

echo "[1/4] Identities"
generate_identity piri
generate_identity ingot

# --- The Piri delegation to sprue ------------------------------------------

# Signed by Piri's own key, so central cannot issue it: this is the half of
# onboarding that has to originate on the node. Onboarding hands it to sprue as
# the third argument of `provider register`.
echo "[2/4] Piri delegation to sprue"
if bao_has piri sprue_proof; then
  echo "  already issued"
else
  pem="$WORK_DIR/piri-signing.pem"
  install -m 0600 /dev/null "$pem"
  # The trailing newline matters: a PEM whose END line runs into EOF is not
  # reliably decodable, and OpenBao returns the value without one.
  { bao_get piri identity_pem; echo; } >"$pem"

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
  bao_put_if_absent piri sprue_proof "$proof"
  echo "  issued"
fi

# --- The owner wallet -------------------------------------------------------

# The EVM account Piri registers as its owner on-chain. It signs nothing in
# normal operation — the central signing service does that for the payer — but
# it is the identity the provider registry records, so losing it means
# re-registering.
echo "[3/4] Owner wallet"
if bao_has piri owner_wallet_key; then
  bao_has piri owner_wallet_address ||
    die "piri has an owner wallet key in OpenBao but no address beside it. Derive it — read the
       key from OpenBao and pipe it to 'cast wallet address' — and write it to
       $FILONE_BAO_MOUNT/piri#owner_wallet_address."
  echo "  already generated ($(bao_get piri owner_wallet_address))"
else
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

  bao_put_if_absent piri owner_wallet_key "$private_key" owner_wallet_address "$address"
  unset private_key
  echo "  generated: $address"
fi

# --- Passwords --------------------------------------------------------------

# Hex, all of them. postgres-init interpolates these into SQL string literals,
# which is safe exactly because a hex string contains no quote to escape.
echo "[4/4] Passwords and root credentials"
generate_password() {
  local path="$1" field="$2" bytes="${3:-32}"
  if bao_has "$path" "$field"; then
    echo "  $path#$field already set"
    return 0
  fi
  bao_put_if_absent "$path" "$field" "$(openssl rand -hex "$bytes")"
}

generate_password postgres admin_password
generate_password postgres piri_password
generate_password postgres ingot_password

# Ingot's break-glass S3 account. Tenant credentials are minted by hilt; these
# exist for the case where hilt cannot be reached and someone has to look at
# what the gateway is holding.
generate_password ingot root_access_key 16
generate_password ingot root_secret_key 32

echo "=== keygen complete ==="
