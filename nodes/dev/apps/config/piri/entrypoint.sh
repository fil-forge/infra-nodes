#!/bin/sh
# Piri's entrypoint on a FilOne Appliance node.
#
# Piri has a two-stage configuration model: an operator supplies a base config,
# `piri init` merges it with what the node discovers and writes the real config
# into the data directory, and `piri serve full` runs from that. This runs init
# once and serve from then on.
#
# Adapted from smelt's staging entrypoint. Same shape, one node instead of a
# numbered one, and the chain endpoint is the hosted RPC provider from node.env,
# authenticated with the bearer token the container gets in its environment.
set -e

KEY_FILE="/keys/piri.pem"
WALLET_FILE="/keys/owner-wallet.hex"
BASE_CONFIG="/config/piri-base-config.toml"
DATA_DIR="/data/piri"
TEMP_DIR="/tmp/piri"
CONFIG_FILE="${DATA_DIR}/piri-config.toml"

LOTUS_ENDPOINT="${LOTUS_ENDPOINT:?LOTUS_ENDPOINT must be set}"
PUBLIC_URL="${PUBLIC_URL:?PUBLIC_URL must be set}"
PORT="${PORT:-3000}"
HOST="${HOST:-0.0.0.0}"
OPERATOR_EMAIL="${OPERATOR_EMAIL:?OPERATOR_EMAIL must be set}"
REGISTRAR_URL="${REGISTRAR_URL:?REGISTRAR_URL must be set}"

echo "=== Piri entrypoint ==="
echo "  Chain RPC:  $LOTUS_ENDPOINT"
echo "  Public URL: $PUBLIC_URL"
echo "  Registrar:  $REGISTRAR_URL"

mkdir -p "$DATA_DIR" "$TEMP_DIR"

echo "[1/3] Reading the node identity"
# The parse runs on its own line rather than inside the assignment below. Under
# `set -e`, `PIRI_DID=$(... | grep)` aborts on a grep no-match before the checks
# run, which turns an unreadable key file into a silent crash loop.
if ! PARSE_OUTPUT=$(/usr/bin/piri identity parse "$KEY_FILE" 2>&1); then
    echo "ERROR: 'piri identity parse $KEY_FILE' failed:" >&2
    echo "$PARSE_OUTPUT" >&2
    exit 1
fi
PIRI_DID=$(printf '%s\n' "$PARSE_OUTPUT" | grep -oE 'did:key:z[a-zA-Z0-9]+' || true)
if [ -z "$PIRI_DID" ]; then
    echo "ERROR: no did:key in 'piri identity parse $KEY_FILE' output:" >&2
    echo "$PARSE_OUTPUT" >&2
    exit 1
fi
echo "  DID: $PIRI_DID"

echo "[2/3] Initialising"
if [ -f "$CONFIG_FILE" ] && grep -q "proof_set" "$CONFIG_FILE" 2>/dev/null; then
    echo "  config exists, skipping init"
else
    [ -f "$CONFIG_FILE" ] && rm -f "$CONFIG_FILE"
    cd "$DATA_DIR"
    # Built as positional parameters rather than a string run through eval, so
    # every value reaches piri as one argv entry and nothing in it can
    # word-split or inject.
    set -- /usr/bin/piri init \
        --base-config="$BASE_CONFIG" \
        --registrar-url="$REGISTRAR_URL" \
        --data-dir="$DATA_DIR" \
        --temp-dir="$TEMP_DIR" \
        --key-file="$KEY_FILE" \
        --wallet-file="$WALLET_FILE" \
        --lotus-endpoint="$LOTUS_ENDPOINT" \
        --public-url="$PUBLIC_URL" \
        --port="$PORT" \
        --host="$HOST" \
        --operator-email="$OPERATOR_EMAIL" \
        --db-type=postgres \
        --db-postgres-url="${PIRI_DB_POSTGRES_URL:?PIRI_DB_POSTGRES_URL must be set}"

    # init calls the registrar for approval, which returns 403 for any DID that
    # is not on the delegator's allow list. That write is the first step of
    # onboarding, so a 403 here means onboarding has not run.
    "$@"
    echo "  init complete"
fi

echo "[3/3] Serving"
# No "$@" here. The init branch above rebuilt it with `set --`, so on a first
# boot it still holds the whole init argv and `serve full` dies on
# `unknown flag: --base-config`.
exec /usr/bin/piri serve full --config "$CONFIG_FILE"
