#!/usr/bin/env bash
# Renew the token this node's OpenBao unseals with.
#
# Runs daily from filone-seal-token-renew.timer. OpenBao renews this token
# itself while it is running, through the lifetime watcher on its transit seal,
# so this exists for the case that watcher cannot cover: a container that has
# been stopped, or a box that has been off, for longer than the token's period.
# Let the period lapse and the node cannot unseal, which needs an operator and a
# new token from central.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init

[ -r "$FILONE_SEAL_TOKEN_FILE" ] || die "no seal token at $FILONE_SEAL_TOKEN_FILE"

BAO_CONFIG="$FILONE_NODE_DIR/platform/config/openbao/bao.hcl"

# The seal stanza in bao.hcl is the only statement of where central is, so read
# it from there rather than keeping a second copy that can disagree with the one
# OpenBao actually uses.
central_addr="$(sed -n 's/^[[:space:]]*address[[:space:]]*=[[:space:]]*"\(https\?:[^"]*\)".*/\1/p' \
  "$BAO_CONFIG" | head -1)"
[ -n "$central_addr" ] || die "no seal address in $BAO_CONFIG"

response="$(curl -sS --max-time 30 -w '\n%{http_code}' \
  --header "X-Vault-Token: $(cat "$FILONE_SEAL_TOKEN_FILE")" \
  --request POST \
  "$central_addr/v1/auth/token/renew-self")"

status="$(printf '%s' "$response" | tail -1)"
body="$(printf '%s' "$response" | sed '$d')"

case "$status" in
  200)
    ttl="$(printf '%s' "$body" | python3 -c \
      'import json,sys; print(json.load(sys.stdin)["auth"]["lease_duration"])' 2>/dev/null || echo unknown)"
    echo "seal token renewed at $central_addr, ${ttl}s remaining"
    ;;
  403)
    # The kill lever, seen from this end. A revoked token is a deliberate act at
    # central, and the node keeps running until something restarts OpenBao.
    die "central refused to renew the seal token (403). It has been revoked or has expired.
       This node cannot unseal after its next restart until an operator mints a new token."
    ;;
  *)
    die "renewing the seal token failed with HTTP $status: $body"
    ;;
esac
