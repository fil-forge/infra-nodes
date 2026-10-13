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
# Written when a re-run of init fails and the existing config is served
# instead. It holds what was attempted: the binary's hash, the config version
# it writes and the inputs hash. While all three match, later starts skip init
# rather than hold off serving for another failed run on every restart. A new
# image or a change to the inputs retries; so does deleting it. A successful
# init, or a start that needs none, removes it.
INIT_FAILED="${DATA_DIR}/piri-init.failed"
# How long a re-run of init may take before it is killed and the existing
# config served instead. A first init has no config to fall back to and is not
# bounded. KILL, because piri catches SIGTERM and init does not stop on it.
# The config as it was before a re-run of init, kept for the length of the run
# so the proof set check after it can put it back.
CONFIG_BEFORE="${DATA_DIR}/piri-config.toml.before-init"

# The proof set IDs a config names, sorted and on one line; empty if it names
# none or does not exist.
proof_sets() {
    sed -n 's/^[[:space:]]*proof_set[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$1" 2>/dev/null |
        sort -u | tr '\n' ' '
}
INIT_TIMEOUT="${PIRI_INIT_TIMEOUT-300}"
case "$INIT_TIMEOUT" in
    ""|*[!0-9]*|0*)
        echo "WARNING: PIRI_INIT_TIMEOUT='$INIT_TIMEOUT' is not a whole number of seconds without leading zeros; using 300" >&2
        INIT_TIMEOUT=300 ;;
esac

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
# Re-running it is safe while its database still has this node's proof set.
# `piri init` reuses an existing provider registration, reuses the one proof set
# its Postgres lists, and skips delegator registration for a DID that is already
# registered, so a second run re-merges and rewrites the config without touching
# anything on chain. If that database lists none -- it was reset, or a changed
# DSN points init at another one -- init creates a new proof set on chain. That
# cannot be stopped from here, so the check after init refuses to serve it.
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
# The binary is in the attempt, not only the config version it writes, so a
# fixed image that writes the same version retries.
ATTEMPT=$(printf 'binary=%s\nconfig_version=%s\ninputs=%s\n' \
    "$(sha256sum /usr/bin/piri | cut -d' ' -f1)" "$WANT_VERSION" "$INPUTS")

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
    # A start that needs no init has nothing to retry; a marker left from an
    # earlier attempt would otherwise match again if those inputs come back.
    rm -f "$INIT_FAILED" 2>/dev/null || true
elif [ "$REASON" != "no config yet" ] && [ "$(cat "$INIT_FAILED" 2>/dev/null)" = "$ATTEMPT" ]; then
    echo "WARNING: skipping init: it already failed for this Piri and these inputs; serving the existing config version $HAVE_VERSION. docs/RUNBOOK.md says how to retry" >&2
else
    case "$REASON" in
        version) echo "  re-running init: this Piri writes config version $WANT_VERSION, the config on disk is $HAVE_VERSION" ;;
        migration) echo "  re-running init once to write its stamp" ;;
        *) echo "  running init: $REASON" ;;
    esac
    # CONFIG_FILE is left in place, so a run that dies on a network call partway
    # through still leaves the node a config to serve. Piri since
    # fil-forge/piri#138 replaces it atomically; older binaries truncate it
    # before writing.
    cd "$DATA_DIR"
    # A re-run is bounded; see INIT_TIMEOUT. The timeout is BusyBox's in the
    # Alpine-based Piri image.
    if [ "$REASON" != "no config yet" ]; then
        set -- timeout -s KILL "$INIT_TIMEOUT" "$@"
    fi
    # On a re-run, the proof set the node has been proving and a copy of the
    # config that names it, for the check after init.
    OLD_PROOF_SET=""
    if [ "$REASON" != "no config yet" ]; then
        OLD_PROOF_SET=$(proof_sets "$CONFIG_FILE")
        cp -p "$CONFIG_FILE" "$CONFIG_BEFORE"
    fi

    # init calls the registrar for approval, which returns 403 for any DID that
    # is not on the delegator's allow list. That write is the first step of
    # onboarding, so a 403 here means onboarding has not run.
    #
    # stdout goes nowhere. The generated config carries the chain RPC bearer
    # token, and the container's stdout is the log Alloy ships to Grafana Cloud.
    # Older binaries always print the config there; since fil-forge/piri#138
    # init prints it only when stdout is not a terminal, which /dev/null counts
    # as, but the log pipe does not. Nothing is lost: the same bytes are what
    # init writes to CONFIG_FILE. Progress and every error go to stderr and stay
    # on the console.
    INIT_STATUS=0
    "$@" >/dev/null || INIT_STATUS=$?
    # 124 or 137: the timeout killed it (137 also covers any other SIGKILL).
    INIT_TIMED_OUT=""
    if [ "$REASON" != "no config yet" ]; then
        case "$INIT_STATUS" in 124|137) INIT_TIMED_OUT=1 ;; esac
    fi
    # A re-run must leave the node on the proof set it had. If the config now
    # names a different one, init made it -- on chain, and in the database it
    # used -- and serving it would move the node off the proof set its data is
    # in. The old config goes back and is served; the new proof set is left for
    # an operator. A config left with no proof set at all (an older binary
    # truncates before writing) is put back too, and the outcome below is
    # decided as before.
    PROOF_SET_CHANGED=""
    if [ -n "$OLD_PROOF_SET" ]; then
        NEW_PROOF_SET=$(proof_sets "$CONFIG_FILE")
        if [ "$NEW_PROOF_SET" != "$OLD_PROOF_SET" ]; then
            [ -n "$NEW_PROOF_SET" ] && PROOF_SET_CHANGED=1
            mv -f "$CONFIG_BEFORE" "$CONFIG_FILE"
        fi
    fi
    rm -f "$CONFIG_BEFORE" 2>/dev/null || true
    if [ -n "$PROOF_SET_CHANGED" ]; then
        printf '%s\n' "$ATTEMPT" > "$INIT_FAILED" ||
        echo "WARNING: could not write $INIT_FAILED; init will run again on the next start" >&2
        echo "ERROR: init wrote a config naming proof set ${NEW_PROOF_SET% } in place of ${OLD_PROOF_SET% }, so it created a new one on chain. Serving the previous config; docs/RUNBOOK.md says what to check before retrying" >&2
    elif [ "$INIT_STATUS" -eq 0 ]; then
        printf '%s\n' "$INPUTS" > "$INIT_STAMP"
        rm -f "$INIT_FAILED" 2>/dev/null || true
        echo "  init complete"
    elif { [ "$REASON" = "version" ] || [ "$REASON" = "migration" ] || [ -n "$INIT_TIMED_OUT" ]; } &&
         grep -q "proof_set" "$CONFIG_FILE" 2>/dev/null; then
        if [ -n "$INIT_TIMED_OUT" ]; then
            echo "WARNING: init did not finish within ${INIT_TIMEOUT}s and was killed" >&2
        fi
        printf '%s\n' "$ATTEMPT" > "$INIT_FAILED" ||
        echo "WARNING: could not write $INIT_FAILED; init will run again on the next start" >&2
        echo "WARNING: init failed; serving the existing config version $HAVE_VERSION. Not retrying until the image or init's inputs change, or $INIT_FAILED is deleted" >&2
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
