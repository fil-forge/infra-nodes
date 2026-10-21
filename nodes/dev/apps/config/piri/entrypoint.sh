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
# A hash of everything init's output depends on apart from the binary: the base
# config and init's own arguments. Compared on every boot, because a changed
# address, service URL or flag has to reach the generated config. A hash rather
# than a copy, so the arguments' Postgres password is not written out once more;
# that is tidiness rather than protection, since the config beside it holds the
# same DSN.
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
# The config as it was before a re-run of init, kept for the length of the run
# so the proof set check after it can put it back. One still here at the next
# start is from a run that never finished, and is put back before anything
# else reads the config.
CONFIG_BEFORE="${DATA_DIR}/piri-config.toml.before-init"

# The proof set IDs a config names, sorted and on one line; empty if it names
# none or does not exist.
proof_sets() {
    sed -n 's/^[[:space:]]*proof_set[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$1" 2>/dev/null |
        sort -u | tr '\n' ' '
}

# How long a re-run of init may take before it is killed and the existing
# config served instead. A first init has no config to fall back to and is not
# bounded. KILL, because piri catches SIGTERM and init does not stop on it.
INIT_TIMEOUT="${PIRI_INIT_TIMEOUT-300}"
case "$INIT_TIMEOUT" in
    ""|*[!0-9]*|0*)
        echo "WARNING: PIRI_INIT_TIMEOUT='$INIT_TIMEOUT' is not a whole number of seconds without leading zeros; using 300" >&2
        INIT_TIMEOUT=300 ;;
esac
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
# run: to init, so the generated config records it, and to serve as well, so
# serve uses the current directory even on a boot where a re-run of init fails
# or times out and serve falls back to a config written before a change to it.
# `piri init` ignores a `[ucan] plc_directory` in the base config; the flag is
# the only way into init.
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
    --lotus-endpoint="$PIRI_PDP_LOTUS_ENDPOINT" \
    --public-url="$PUBLIC_URL" \
    --port="$PORT" \
    --host="$HOST" \
    --operator-email="$OPERATOR_EMAIL" \
    --db-type=postgres \
    --db-postgres-url="${PIRI_DB_POSTGRES_URL:?PIRI_DB_POSTGRES_URL must be set}"
# The chain RPC token is not in the hash: CONFIG_FILE is kept without it and
# `serve` reads it from the environment, so a rotation needs only a recreate.
# The key and wallet files' contents are deliberately not in it either: init
# run with a different wallet could register a new provider and create a new
# proof set on chain, and that should never happen as a side effect of a
# restart.
INPUTS=$( { cat "$BASE_CONFIG"; printf '%s\n' "$@"; } | sha256sum | cut -d' ' -f1)

# A copy left by a re-run that never finished -- the container was killed after
# init wrote its config but before the check below ran -- goes back first.
# Otherwise this start would read, and copy as its baseline, whatever that run
# wrote, proof set and all.
if [ -f "$CONFIG_BEFORE" ]; then
    echo "WARNING: restoring the config from before an init that did not finish" >&2
    mv -f "$CONFIG_BEFORE" "$CONFIG_FILE" || {
        echo "ERROR: could not restore $CONFIG_FILE from $CONFIG_BEFORE; not serving the config an unfinished init left" >&2
        exit 1
    }
fi

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
    REASON="the base config or init's arguments changed"
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
    if ! grep -q " $INIT_DIR tmpfs " /proc/mounts; then
        echo "ERROR: $INIT_DIR is not a tmpfs; init would write the chain RPC token to disk" >&2
        exit 1
    fi
    # init writes into the tmpfs, and CONFIG_FILE is replaced only once it has
    # succeeded, so a run that dies on a network call partway through still
    # leaves the node a config to serve.
    cd "$INIT_DIR"
    rm -f piri-config.toml
    # A re-run is bounded; see INIT_TIMEOUT. The timeout is BusyBox's in the
    # Alpine-based Piri image.
    if [ "$REASON" != "no config yet" ]; then
        set -- timeout -s KILL "$INIT_TIMEOUT" "$@"
    fi
    # On a re-run, the proof set the node has been proving and a copy of the
    # config that names it, for the check after init.
    # Without the copy the check has nothing to put back, so init does not run
    # and the outcome is decided as for a failed run.
    OLD_PROOF_SET=""
    INIT_SKIPPED=""
    if [ "$REASON" != "no config yet" ]; then
        OLD_PROOF_SET=$(proof_sets "$CONFIG_FILE")
        if ! cp -p "$CONFIG_FILE" "$CONFIG_BEFORE"; then
            rm -f "$CONFIG_BEFORE" 2>/dev/null || true
            echo "WARNING: could not copy $CONFIG_FILE before init, so init did not run" >&2
            INIT_SKIPPED=1
        fi
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
    # init writes to piri-config.toml. Progress and every error go to stderr and
    # stay on the console.
    INIT_STATUS=0
    if [ -n "$INIT_SKIPPED" ]; then
        INIT_STATUS=1
    else
        "$@" >/dev/null || INIT_STATUS=$?
    fi
    # `serve` reads the token from the environment, so CONFIG_FILE gets init's
    # config without it. The rename keeps a crash from leaving half a config on
    # the data volume. Whatever init wrote goes there even when it failed, so
    # the proof set check below sees a proof set a failed run created; the
    # check puts the old config back after any failure. When init cannot create
    # the file it prints the config to stdout instead, which goes nowhere, and
    # still exits 0; that counts as a failed run.
    if [ -s piri-config.toml ]; then
        if ! { grep -v '^[[:space:]]*lotus_auth_token[[:space:]]*=' piri-config.toml >"$CONFIG_FILE.new" &&
               mv "$CONFIG_FILE.new" "$CONFIG_FILE"; }; then
            echo "ERROR: could not write $CONFIG_FILE from init's output" >&2
            rm -f "$CONFIG_FILE.new" 2>/dev/null || true
            INIT_STATUS=1
        fi
    elif [ "$INIT_STATUS" -eq 0 ]; then
        echo "ERROR: piri init wrote no piri-config.toml in $INIT_DIR" >&2
        INIT_STATUS=1
    fi
    rm -f piri-config.toml 2>/dev/null || true
    # 124 or 137: the timeout killed it (137 also covers any other SIGKILL).
    INIT_TIMED_OUT=""
    if [ "$REASON" != "no config yet" ]; then
        case "$INIT_STATUS" in 124|137) INIT_TIMED_OUT=1 ;; esac
    fi
    # A re-run must leave the node on the proof set it had. If the config now
    # names a different one, init created or adopted it -- on chain, or from the
    # database it used -- and serving it would move the node off the proof set
    # its data is in. The old config goes back and is served; the new proof set
    # is left for an operator.
    #
    # The copy also goes back after any run that did not succeed, and after one
    # that exited 0 but left no proof set (an older binary truncates the config
    # before writing it, and returns 0 when the write fails). Either way the
    # config on disk is not one init finished, so it is not served, and such a
    # run is not counted as a success: its stamp would claim inputs the config
    # does not reflect.
    PROOF_SET_CHANGED=""
    if [ -f "$CONFIG_BEFORE" ]; then
        NEW_PROOF_SET=$(proof_sets "$CONFIG_FILE")
        if [ -n "$OLD_PROOF_SET" ] && [ -n "$NEW_PROOF_SET" ] && [ "$NEW_PROOF_SET" != "$OLD_PROOF_SET" ]; then
            PROOF_SET_CHANGED=1
        fi
        if [ -n "$PROOF_SET_CHANGED" ] || { [ -n "$OLD_PROOF_SET" ] && [ -z "$NEW_PROOF_SET" ]; } || [ "$INIT_STATUS" -ne 0 ]; then
            mv -f "$CONFIG_BEFORE" "$CONFIG_FILE"
            if [ "$INIT_STATUS" -eq 0 ]; then
                [ -z "$PROOF_SET_CHANGED" ] && echo "WARNING: init exited 0 but left no proof set in the config; restored the previous one" >&2
                INIT_STATUS=1
            fi
        fi
    fi
    rm -f "$CONFIG_BEFORE" 2>/dev/null || true
    if [ -n "$PROOF_SET_CHANGED" ]; then
        printf '%s\n' "$ATTEMPT" > "$INIT_FAILED" ||
        echo "WARNING: could not write $INIT_FAILED; init will run again on the next start" >&2
        echo "ERROR: init wrote a config naming proof set ${NEW_PROOF_SET% } in place of ${OLD_PROOF_SET% }, so it created or adopted another one. Serving the previous config; docs/RUNBOOK.md says what to check before retrying" >&2
    elif [ "$INIT_STATUS" -eq 0 ]; then
        printf '%s\n' "$INPUTS" > "$INIT_STAMP"
        rm -f "$INIT_FAILED" 2>/dev/null || true
        echo "  init complete"
    elif { [ "$REASON" = "version" ] || [ "$REASON" = "migration" ] || [ -n "$INIT_TIMED_OUT" ]; } &&
         grep -q "proof_set" "$CONFIG_FILE" 2>/dev/null; then
        if [ -n "$INIT_TIMED_OUT" ]; then
            echo "WARNING: init did not finish within ${INIT_TIMEOUT}s and was killed" >&2
        fi
        # No marker when init never ran: the next start should try again.
        if [ -z "$INIT_SKIPPED" ]; then
            printf '%s\n' "$ATTEMPT" > "$INIT_FAILED" ||
            echo "WARNING: could not write $INIT_FAILED; init will run again on the next start" >&2
        fi
        if [ -n "$INIT_SKIPPED" ]; then
            echo "WARNING: serving the existing config version $HAVE_VERSION; init will run on the next start" >&2
        else
            echo "WARNING: init failed; serving the existing config version $HAVE_VERSION. Not retrying until the image or init's inputs change, or $INIT_FAILED is deleted" >&2
        fi
    else
        if [ -n "$INIT_SKIPPED" ]; then
            echo "ERROR: init did not run" >&2
        else
            echo "ERROR: init failed" >&2
        fi
        exit 1
    fi
fi

# Entrypoints before the tmpfs ran init in the data directory and left the
# token in CONFIG_FILE. A config that skipped init above may still hold it.
if grep -q '^[[:space:]]*lotus_auth_token[[:space:]]*=' "$CONFIG_FILE"; then
    echo "  removing the chain RPC token an older init left in the config"
    sed -i '/^[[:space:]]*lotus_auth_token[[:space:]]*=/d' "$CONFIG_FILE"
fi

echo "[3/3] Serving"
# No "$@" here. It holds init's argv from above, and `serve full` dies on
# `unknown flag: --base-config`.
exec /usr/bin/piri serve full --config "$CONFIG_FILE" \
    --plc-directory="$PLC_DIRECTORY_URL"
