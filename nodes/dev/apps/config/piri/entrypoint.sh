#!/bin/sh
# Piri's entrypoint on a FilOne Appliance node.
#
# Piri has a two-stage configuration model: an operator supplies a base config,
# `piri init` merges it with what the node discovers and writes the real config
# into the data directory, and `piri serve full` runs from that. This runs init
# once and serve from then on.
#
# Adapted from smelt's staging entrypoint. Every Piri on the node runs this same
# script: each container mounts its own key, wallet and data directory at the
# paths below, and gets its own PUBLIC_URL. The chain endpoint is the hosted RPC
# provider from node.env, authenticated with the bearer token the container gets
# in its environment.
set -e

KEY_FILE="/keys/piri.pem"
WALLET_FILE="/keys/owner-wallet.hex"
BASE_CONFIG="/config/piri-base-config.toml"
DATA_DIR="/data/piri"
TEMP_DIR="/tmp/piri"
CONFIG_FILE="${DATA_DIR}/piri-config.toml"
# The base config init last merged from. Compared on every boot, because a
# changed address or service URL has to reach the generated config.
BASE_CONFIG_SNAPSHOT="${DATA_DIR}/piri-base-config.applied.toml"
# `piri init` writes piri-config.toml into its working directory, and the file
# holds the chain RPC token. Init runs in this tmpfs, so the token never reaches
# the data volume; only a copy without it does.
INIT_DIR="/run/piri-init"

PIRI_PDP_LOTUS_ENDPOINT="${PIRI_PDP_LOTUS_ENDPOINT:?PIRI_PDP_LOTUS_ENDPOINT must be set}"
# Not echoed. `serve` reads it from here only, since the config on the data
# volume is kept without it.
PIRI_PDP_LOTUS_AUTH_TOKEN="${PIRI_PDP_LOTUS_AUTH_TOKEN:?PIRI_PDP_LOTUS_AUTH_TOKEN must be set}"
PUBLIC_URL="${PUBLIC_URL:?PUBLIC_URL must be set}"
PORT="${PORT:-3000}"
HOST="${HOST:-0.0.0.0}"
OPERATOR_EMAIL="${OPERATOR_EMAIL:?OPERATOR_EMAIL must be set}"
REGISTRAR_URL="${REGISTRAR_URL:?REGISTRAR_URL must be set}"
# The did:plc directory tenant identities resolve from. It is passed on every
# run: to init, so the generated config records it, and to serve, because init
# only re-runs when the base config changes and this value is not part of the
# base config. `piri init` ignores a `[ucan] plc_directory` in the base config;
# the flag is the only way into init.
PLC_DIRECTORY_URL="${PLC_DIRECTORY_URL:?PLC_DIRECTORY_URL must be set}"

echo "=== Piri entrypoint ==="
echo "  Chain RPC:  $PIRI_PDP_LOTUS_ENDPOINT"
echo "  Public URL: $PUBLIC_URL"
echo "  Registrar:  $REGISTRAR_URL"
echo "  PLC:        $PLC_DIRECTORY_URL"

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
# init merges the base config with what it discovers on chain and from the
# registrar, and writes the result to CONFIG_FILE. Skipping it once a config
# exists would strand every later edit to the base config: a changed contract
# address, payer or service URL would recreate this container and never reach
# the config Piri actually serves from.
#
# Re-running it is safe. `piri init` reuses an existing provider registration
# and an existing proof set, and skips delegator registration for a DID that is
# already registered, so a second run re-merges and rewrites the config without
# touching anything on chain.
if [ -f "$CONFIG_FILE" ] && grep -q "proof_set" "$CONFIG_FILE" 2>/dev/null &&
   cmp -s "$BASE_CONFIG" "$BASE_CONFIG_SNAPSHOT"; then
    echo "  config exists and the base config is unchanged, skipping init"
else
    if [ -f "$CONFIG_FILE" ]; then
        echo "  re-running init to pick up the current base config"
    fi
    if ! grep -q " $INIT_DIR tmpfs " /proc/mounts; then
        echo "ERROR: $INIT_DIR is not a tmpfs; init would write the chain RPC token to disk" >&2
        exit 1
    fi
    # CONFIG_FILE stays in place until init has succeeded, so a run that dies
    # on a network call partway through leaves the node with its last config.
    cd "$INIT_DIR"
    rm -f piri-config.toml
    # Built as positional parameters rather than a string run through eval, so
    # every value reaches piri as one argv entry and nothing in it can
    # word-split or inject.
    set -- /usr/bin/piri init \
        --base-config="$BASE_CONFIG" \
        --registrar-url="$REGISTRAR_URL" \
        --plc-directory="$PLC_DIRECTORY_URL" \
        --data-dir="$DATA_DIR" \
        --temp-dir="$TEMP_DIR" \
        --key-file="$KEY_FILE" \
        --wallet-file="$WALLET_FILE" \
        --lotus-endpoint="$PIRI_PDP_LOTUS_ENDPOINT" \
        --public-url="$PUBLIC_URL" \
        --port="$PORT" \
        --host="$HOST" \
        --operator-email="$OPERATOR_EMAIL" \
        --db-type=postgres \
        --db-postgres-url="${PIRI_DB_POSTGRES_URL:?PIRI_DB_POSTGRES_URL must be set}"

    # init calls the registrar for approval, which returns 403 for any DID that
    # is not on the delegator's allow list. That write is the first step of
    # onboarding, so a 403 here means onboarding has not run.
    #
    # stdout goes nowhere. init prints the generated config there, and that
    # config carries the chain RPC bearer token, which would land in the
    # container log Alloy ships to Grafana Cloud. Nothing is lost: the same
    # bytes are what init writes to piri-config.toml. Progress and every error
    # go to stderr and stay on the console.
    "$@" >/dev/null
    # When init cannot create the file it prints the config to stdout instead,
    # which goes nowhere, and still exits 0.
    if [ ! -s piri-config.toml ]; then
        echo "ERROR: piri init wrote no piri-config.toml in $INIT_DIR" >&2
        exit 1
    fi
    # `serve` reads the token from the environment. The rename keeps a crash
    # from leaving half a config on the data volume.
    grep -v '^[[:space:]]*lotus_auth_token[[:space:]]*=' piri-config.toml >"$CONFIG_FILE.new"
    mv "$CONFIG_FILE.new" "$CONFIG_FILE"
    rm -f piri-config.toml
    cp "$BASE_CONFIG" "$BASE_CONFIG_SNAPSHOT"
    echo "  init complete"
fi

# Entrypoints before the tmpfs ran init in the data directory and left the
# token in CONFIG_FILE. A config that skipped init above may still hold it.
if grep -q '^[[:space:]]*lotus_auth_token[[:space:]]*=' "$CONFIG_FILE"; then
    echo "  removing the chain RPC token an older init left in the config"
    sed -i '/^[[:space:]]*lotus_auth_token[[:space:]]*=/d' "$CONFIG_FILE"
fi

echo "[3/3] Serving"
# No "$@" here. The init branch above rebuilt it with `set --`, so on a first
# boot it still holds the whole init argv and `serve full` dies on
# `unknown flag: --base-config`.
exec /usr/bin/piri serve full --config "$CONFIG_FILE" \
    --plc-directory="$PLC_DIRECTORY_URL"
