#!/usr/bin/env bash
# Generate a new root token for this node's OpenBao from its recovery key, when
# no valid root token exists. docs/runbook/replace-openbao-root-token.md says
# when to run it.
#
# OpenBao 2.6 serves root generation only to an authenticated caller, so this
# runs as the host token, whose filone-host policy allows the attempt. Only the
# recovery key completes it. Paste it from 1Password, or from central's copy.
#
# It refuses to run while an attempt it did not start is in progress: whoever
# started that attempt chose its one-time password, and a recovery key given to
# it would hand them the new root token.
#
# Prints the new root token once. Store it in 1Password and at central, together
# with the unchanged recovery key.
#
# Usage:
#   scripts/host/regenerate-root-token.sh
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

bao_is_unsealed || die "OpenBao is sealed; root generation needs it unsealed"
[ -r "$FILONE_BAO_TOKEN_FILE" ] || die "no host token at $FILONE_BAO_TOKEN_FILE"

BAO_TOKEN="$(cat "$FILONE_BAO_TOKEN_FILE")"
export BAO_TOKEN

gen() { bao_in "$FILONE_BAO_CONTAINER" operator generate-root "$@"; }

echo "=== regenerate root token ($FILONE_NODE) ==="
echo

status="$(gen -status -format=json </dev/null)" || die "could not read the root generation status. A host
     token minted before its policy allowed root generation is refused; only
     provision-host-token.sh, which takes a root token, grants it."
[ "$(jq -r .started <<<"$status")" = false ] || die "a root generation attempt is already in
     progress, and this script did not start it. Do not give it the recovery key.
     Find out who started it before cancelling it with
     'bao operator generate-root -cancel'."

otp="$(gen -generate-otp </dev/null)"
nonce="$(gen -init -otp="$otp" -format=json </dev/null | jq -r .nonce)"

# Cancel this script's own attempt unless it completes, so a wrong key or an
# interrupted run leaves nothing in progress.
completed=false
trap '[ "$completed" = true ] || gen -cancel </dev/null >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM HUP
[ -n "$nonce" ] || die "OpenBao started no attempt"

echo "  Paste this node's recovery key. It is not echoed here."
read -rsp "recovery key: " recovery_key
echo
[ -n "$recovery_key" ] || die "no recovery key given"

# printf is a builtin, so the key reaches OpenBao on stdin and is never an
# argument of any process.
encoded="$(printf '%s' "$recovery_key" | gen -nonce="$nonce" -format=json - | jq -r '.encoded_token // empty')"
unset recovery_key
[ -n "$encoded" ] || die "OpenBao returned no token; check that the key is this node's recovery key"
completed=true

echo
echo "  New root token, shown once:"
echo
printf '%s' "$encoded" | gen -decode=- -otp="$otp"
echo
echo
echo "  Store it in 1Password, replacing the lost one, and at central with the"
echo "  unchanged recovery key: 'make store-appliance-root-credentials' in"
echo "  infra-central. Then clear this terminal's scrollback."
