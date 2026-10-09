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
# A hash of everything init's output depends on apart from the binary: the base
# config, init's own arguments and the chain RPC token init writes into the
# config. Compared on every boot, because a changed address, service URL, flag
# or token has to reach the generated config. A hash rather than a copy, so the
# arguments' Postgres password is not written out once more; that is tidiness
# rather than protection, since the config beside it holds the same DSN.
INIT_STAMP="${DATA_DIR}/piri-init.stamp"
# What earlier versions of this script kept instead: a copy of the base config
# alone. No longer written. It is left on disk rather than deleted, so a revert
# to that script, and the gate's check that init has completed here, still find
# it.
LEGACY_SNAPSHOT="${DATA_DIR}/piri-base-config.applied.toml"
# How long a re-run of init may take before it is killed and the existing
# config served instead. A first init has no config to fall back to and is not
# bounded. KILL, because piri catches SIGTERM and init does not stop on it.
INIT_TIMEOUT="${PIRI_INIT_TIMEOUT:-600}"

LOTUS_ENDPOINT="${LOTUS_ENDPOINT:?LOTUS_ENDPOINT must be set}"
PUBLIC_URL="${PUBLIC_URL:?PUBLIC_URL must be set}"
PORT="${PORT:-3000}"
HOST="${HOST:-0.0.0.0}"
OPERATOR_EMAIL="${OPERATOR_EMAIL:?OPERATOR_EMAIL must be set}"
REGISTRAR_URL="${REGISTRAR_URL:?REGISTRAR_URL must be set}"
# The did:plc directory tenant identities resolve from. It is passed on every
# run: to init, so the generated config records it, and to serve as well, so
# serve uses the current directory even on a boot where a re-run of init fails
# or times out and serve falls back to a config written before a change to it.
# `piri init` ignores a `[ucan] plc_directory` in the base config; the flag is
# the only way into init.
PLC_DIRECTORY_URL="${PLC_DIRECTORY_URL:?PLC_DIRECTORY_URL must be set}"

echo "=== Piri entrypoint ==="
echo "  Chain RPC:  $LOTUS_ENDPOINT"
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
# exists would strand every later edit: a changed contract address, payer,
# service URL or flag would recreate this container and never reach the config
# Piri actually serves from.
#
# Re-running it is safe. `piri init` reuses an existing provider registration
# and an existing proof set, and skips delegator registration for a DID that is
# already registered, so a second run re-merges and rewrites the config without
# touching anything on chain.
#
# Built as positional parameters rather than a string run through eval, so
# every value reaches piri as one argv entry and nothing in it can word-split
# or inject.
set -- /usr/bin/piri init \
    --base-config="$BASE_CONFIG" \
    --registrar-url="$REGISTRAR_URL" \
    --plc-directory="$PLC_DIRECTORY_URL" \
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
# The token is in the hash because init writes it into CONFIG_FILE, so a
# rotation has to re-run init or the revoked token stays on disk. The key and
# wallet files' contents are deliberately not: init run with a different wallet
# could register a new provider and create a new proof set on chain, and that
# should never happen as a side effect of a restart.
INPUTS=$( { cat "$BASE_CONFIG"; printf '%s\n' "$@" "${PIRI_PDP_LOTUS_AUTH_TOKEN:-}"; } |
    sha256sum | cut -d' ' -f1)

# The version of the config this binary's init writes, and the version of the
# one on disk. A binary too old to report one prints nothing and is left out of
# the decision; a config written before the field existed counts as 0.
WANT_VERSION=$(/usr/bin/piri version --config-version 2>/dev/null || true)
case "$WANT_VERSION" in *[!0-9]*|"") WANT_VERSION="" ;; esac
HAVE_VERSION=$(sed -n 's/^config_version = \([0-9][0-9]*\)$/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n 1)
HAVE_VERSION="${HAVE_VERSION:-0}"

# Why init has to run, if it does. Two reasons make a failure not fatal, and
# serve the config on disk instead, because it still reflects every input and
# serving it beats a node that will not start:
#   version    a new binary's config version; the config is in an older shape.
#   migration  the first boot under the stamp. No stamp yet, but the snapshot
#              earlier versions of this script kept matches the base config, so
#              nothing init reads has changed that the snapshot would show.
REASON=""
if [ ! -f "$CONFIG_FILE" ] || ! grep -q "proof_set" "$CONFIG_FILE" 2>/dev/null; then
    REASON="no config yet"
elif [ ! -f "$INIT_STAMP" ] && cmp -s "$LEGACY_SNAPSHOT" "$BASE_CONFIG"; then
    REASON="migration"
elif [ "$(cat "$INIT_STAMP" 2>/dev/null)" != "$INPUTS" ]; then
    REASON="the base config, init's arguments or the RPC token changed"
elif [ -n "$WANT_VERSION" ] && [ "$WANT_VERSION" != "$HAVE_VERSION" ]; then
    REASON="version"
fi

if [ -z "$REASON" ]; then
    echo "  config is current, skipping init"
else
    case "$REASON" in
        version) echo "  re-running init: this Piri writes config version $WANT_VERSION, the config on disk is $HAVE_VERSION" ;;
        migration) echo "  re-running init once to write its stamp" ;;
        *) echo "  running init: $REASON" ;;
    esac
    # CONFIG_FILE is left in place. init truncates it when it writes, and a run
    # that dies on a network call partway through would otherwise leave the node
    # with no config at all.
    cd "$DATA_DIR"
    # A re-run is bounded; see INIT_TIMEOUT. The timeout is BusyBox's in the
    # Alpine-based Piri image.
    if [ "$REASON" != "no config yet" ]; then
        set -- timeout -s KILL "$INIT_TIMEOUT" "$@"
    fi

    # init calls the registrar for approval, which returns 403 for any DID that
    # is not on the delegator's allow list. That write is the first step of
    # onboarding, so a 403 here means onboarding has not run.
    #
    # stdout goes nowhere. init prints the generated config there, and that
    # config carries the chain RPC bearer token, which would land in the
    # container log Alloy ships to Grafana Cloud. Nothing is lost: the same
    # bytes are what init writes to CONFIG_FILE. Progress and every error go to
    # stderr and stay on the console.
    INIT_STATUS=0
    "$@" >/dev/null || INIT_STATUS=$?
    # 124 or 137: the timeout killed it (137 also covers any other SIGKILL).
    INIT_TIMED_OUT=""
    if [ "$REASON" != "no config yet" ]; then
        case "$INIT_STATUS" in 124|137) INIT_TIMED_OUT=1 ;; esac
    fi
    if [ "$INIT_STATUS" -eq 0 ]; then
        printf '%s\n' "$INPUTS" > "$INIT_STAMP"
        echo "  init complete"
    elif { [ "$REASON" = "version" ] || [ "$REASON" = "migration" ] || [ -n "$INIT_TIMED_OUT" ]; } &&
         grep -q "proof_set" "$CONFIG_FILE" 2>/dev/null; then
        if [ -n "$INIT_TIMED_OUT" ]; then
            echo "WARNING: init did not finish within ${INIT_TIMEOUT}s and was killed" >&2
        fi
        echo "WARNING: init failed; serving the existing config version $HAVE_VERSION, and retrying on the next start" >&2
    else
        echo "ERROR: init failed" >&2
        exit 1
    fi
fi

echo "[3/3] Serving"
# No "$@" here. It holds init's argv from above, and `serve full` dies on
# `unknown flag: --base-config`.
exec /usr/bin/piri serve full --config "$CONFIG_FILE" \
    --plc-directory="$PLC_DIRECTORY_URL"
