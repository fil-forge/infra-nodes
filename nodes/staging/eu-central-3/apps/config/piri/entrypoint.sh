#!/bin/sh
set -e

KEY_FILE=/keys/piri.pem
WALLET_FILE=/keys/owner-wallet.hex
BASE_CONFIG=/config/piri-base-config.toml
DATA_DIR=/data/piri
TEMP_DIR=/tmp/piri
CONFIG_FILE="$DATA_DIR/piri-config.toml"
# A hash of the base config and init's arguments; see the dev entrypoint.
INIT_STAMP="$DATA_DIR/piri-init.stamp"
# Earlier versions' copy of the base config. No longer written, and left in
# place so a revert, and pdp-gate.sh, still find it.
LEGACY_SNAPSHOT="$DATA_DIR/piri-base-config.applied.toml"
# Written when a re-run of init fails and the existing config is served: the
# config version and inputs hash attempted. While both match, later starts skip
# init; see the dev entrypoint.
INIT_FAILED="$DATA_DIR/piri-init.failed"
# A re-run of init is killed after this long and the existing config served.
# KILL, because piri catches SIGTERM and init does not stop on it.
INIT_TIMEOUT="${PIRI_INIT_TIMEOUT-300}"
case "$INIT_TIMEOUT" in
  ""|*[!0-9]*|0*)
    echo "WARNING: PIRI_INIT_TIMEOUT='$INIT_TIMEOUT' is not a whole number of seconds without leading zeros; using 300" >&2
    INIT_TIMEOUT=300 ;;
esac

: "${LOTUS_ENDPOINT:?LOTUS_ENDPOINT must be set}"
: "${PUBLIC_URL:?PUBLIC_URL must be set}"
: "${REGISTRAR_URL:?REGISTRAR_URL must be set}"
# Passed to both init and serve, so serve uses the current directory even when
# a re-run of init fails or times out and serve falls back to a config written
# before a change to it. `piri init` ignores a `[ucan] plc_directory` in the
# base config.
: "${PLC_DIRECTORY_URL:?PLC_DIRECTORY_URL must be set}"
: "${OPERATOR_EMAIL:?OPERATOR_EMAIL must be set}"

mkdir -p "$DATA_DIR" "$TEMP_DIR"

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
  --port="${PORT:-3000}" \
  --host="${HOST:-0.0.0.0}" \
  --operator-email="$OPERATOR_EMAIL" \
  --db-type=postgres \
  --db-postgres-url="${PIRI_DB_POSTGRES_URL:?PIRI_DB_POSTGRES_URL must be set}"
# Key and wallet contents are deliberately left out: init run with a different
# wallet could create a new proof set on chain as a side effect of a restart.
INPUTS=$( { cat "$BASE_CONFIG"; printf '%s\n' "$@"; } | sha256sum | cut -d' ' -f1)

# Re-run init when this binary writes a different config version than the one
# on disk. An older binary reports none; an older config counts as 0.
WANT_VERSION=$(/usr/bin/piri version --config-version 2>/dev/null || true)
case "$WANT_VERSION" in *[!0-9]*|"") WANT_VERSION="" ;; esac
HAVE_VERSION=$(sed -n 's/^config_version = \([0-9][0-9]*\)$/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n 1)
HAVE_VERSION="${HAVE_VERSION:-0}"
# The binary is in the attempt, not only the config version it writes, so a
# fixed image that writes the same version retries.
ATTEMPT=$(printf 'binary=%s\nconfig_version=%s\ninputs=%s\n' \
    "$(sha256sum /usr/bin/piri | cut -d' ' -f1)" "$WANT_VERSION" "$INPUTS")

# A failure is not fatal for "version" (only the config's shape is behind) or
# "migration" (the first boot under the stamp, with the old snapshot still
# matching the base config): the config on disk reflects every input.
REASON=""
if [ ! -f "$CONFIG_FILE" ] || ! grep -q proof_set "$CONFIG_FILE" 2>/dev/null; then
  REASON="no config yet"
elif [ ! -f "$INIT_STAMP" ] && cmp -s "$LEGACY_SNAPSHOT" "$BASE_CONFIG"; then
  REASON="migration"
elif [ "$(cat "$INIT_STAMP" 2>/dev/null)" != "$INPUTS" ]; then
  REASON="the base config or init's arguments changed"
elif [ -n "$WANT_VERSION" ] && [ "$WANT_VERSION" != "$HAVE_VERSION" ]; then
  REASON="version"
fi

if [ -z "$REASON" ]; then
  echo "Piri config exists and is current"
  # A start that needs no init has nothing to retry; a marker left from an
  # earlier attempt would otherwise match again if those inputs come back.
  rm -f "$INIT_FAILED"
elif [ "$REASON" != "no config yet" ] && [ "$(cat "$INIT_FAILED" 2>/dev/null)" = "$ATTEMPT" ]; then
  echo "WARNING: skipping init: it already failed for this Piri and these inputs; serving the existing config version $HAVE_VERSION. docs/RUNBOOK.md says how to retry" >&2
else
  case "$REASON" in
    version) echo "Running piri init: this Piri writes config version $WANT_VERSION, the config on disk is $HAVE_VERSION" ;;
    migration) echo "Running piri init once to write its stamp" ;;
    *) echo "Running piri init: $REASON" ;;
  esac
  cd "$DATA_DIR"
  # Only a re-run is bounded: a first init has no config to fall back to.
  if [ "$REASON" != "no config yet" ]; then
    set -- timeout -s KILL "$INIT_TIMEOUT" "$@"
  fi
  INIT_STATUS=0
  "$@" >/dev/null || INIT_STATUS=$?
  # 124 or 137: the timeout killed it.
  INIT_TIMED_OUT=""
  if [ "$REASON" != "no config yet" ]; then
    case "$INIT_STATUS" in 124|137) INIT_TIMED_OUT=1 ;; esac
  fi
  if [ "$INIT_STATUS" -eq 0 ]; then
    printf '%s\n' "$INPUTS" > "$INIT_STAMP"
    rm -f "$INIT_FAILED"
  elif { [ "$REASON" = "version" ] || [ "$REASON" = "migration" ] || [ -n "$INIT_TIMED_OUT" ]; } &&
       grep -q proof_set "$CONFIG_FILE" 2>/dev/null; then
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

exec /usr/bin/piri serve full --config "$CONFIG_FILE" \
  --plc-directory="$PLC_DIRECTORY_URL"
