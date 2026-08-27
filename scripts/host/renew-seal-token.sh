#!/usr/bin/env bash
# Renew the token this node's OpenBao unseals with.
#
# Runs daily from filone-seal-token-renew.timer. OpenBao renews this token itself
# while it is running, through the lifetime watcher on its transit seal, so this
# covers the window where the box is up and that watcher is not: a container
# stopped for debugging, or one crash-looping after a bad deploy, for longer than
# the token's period. Let the period lapse and the node cannot unseal, which
# needs an operator and a new token from central.
#
# Renewing needs no local OpenBao: the token is central's, so this is one HTTPS
# call from the host to central. Unsealing is the operation that needs the local
# server, which is why a stopped one cannot keep its own token alive.
#
# A box that is off renews nothing either way. It comes back to a live token for
# as long as it was off for less than the period, and to a dead one after that.
#
# The daily run also finds a revoked token on the day it is revoked, rather than
# at the next restart, when the node would already be unable to unseal.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init

[ -r "$FILONE_SEAL_TOKEN_FILE" ] || die "no seal token at $FILONE_SEAL_TOKEN_FILE"

central_addr="$(central_seal_addr)"

# curl puts --header values in its own argv, where anything on the host that can
# read /proc can take the token while the request is in flight, so the header
# goes in on stdin. printf is a shell builtin and never gets an argv of its own.
response="$(printf 'X-Vault-Token: %s\n' "$(cat "$FILONE_SEAL_TOKEN_FILE")" |
  curl -sS --max-time 30 -w '\n%{http_code}' --header @- \
    --request POST "$central_addr/v1/auth/token/renew-self")"

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
