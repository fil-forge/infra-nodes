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
LEGACY_SNAPSHOT="$DATA_DIR/piri-base-config.applied.toml"

: "${LOTUS_ENDPOINT:?LOTUS_ENDPOINT must be set}"
: "${PUBLIC_URL:?PUBLIC_URL must be set}"
: "${REGISTRAR_URL:?REGISTRAR_URL must be set}"
# Passed to both init and serve, so it reaches Piri even when a version-only
# re-init fails and serve falls back to the existing config. `piri init`
# ignores a `[ucan] plc_directory` in the base config.
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
INPUTS=$( { cat "$BASE_CONFIG"; printf '%s\n' "$@"; } | sha256sum | cut -d' ' -f1)

# Re-run init when this binary writes a different config version than the one
# on disk. An older binary reports none; an older config counts as 0.
WANT_VERSION=$(/usr/bin/piri version --config 2>/dev/null || true)
case "$WANT_VERSION" in *[!0-9]*|"") WANT_VERSION="" ;; esac
HAVE_VERSION=$(sed -n 's/^config_version = \([0-9][0-9]*\)$/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n 1)
HAVE_VERSION="${HAVE_VERSION:-0}"

REASON=""
if [ ! -f "$CONFIG_FILE" ] || ! grep -q proof_set "$CONFIG_FILE" 2>/dev/null; then
  REASON="no config yet"
elif [ "$(cat "$INIT_STAMP" 2>/dev/null)" != "$INPUTS" ]; then
  REASON="the base config or init's arguments changed"
elif [ -n "$WANT_VERSION" ] && [ "$WANT_VERSION" != "$HAVE_VERSION" ]; then
  REASON="version"
fi

if [ -z "$REASON" ]; then
  echo "Piri config exists and is current"
else
  if [ "$REASON" = "version" ]; then
    echo "Running piri init: this Piri writes config version $WANT_VERSION, the config on disk is $HAVE_VERSION"
  else
    echo "Running piri init: $REASON"
  fi
  cd "$DATA_DIR"
  if "$@" >/dev/null; then
    printf '%s\n' "$INPUTS" > "$INIT_STAMP"
    rm -f "$LEGACY_SNAPSHOT"
  elif [ "$REASON" = "version" ] && grep -q proof_set "$CONFIG_FILE" 2>/dev/null; then
    # Only the config's shape is behind; every input it reflects is current.
    echo "WARNING: init failed; serving config version $HAVE_VERSION until the next start" >&2
  else
    echo "ERROR: init failed" >&2
    exit 1
  fi
fi

exec /usr/bin/piri serve full --config "$CONFIG_FILE" \
  --plc-directory="$PLC_DIRECTORY_URL"
