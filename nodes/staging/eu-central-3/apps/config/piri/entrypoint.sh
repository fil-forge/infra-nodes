#!/bin/sh
set -e

KEY_FILE=/keys/piri.pem
WALLET_FILE=/keys/owner-wallet.hex
BASE_CONFIG=/config/piri-base-config.toml
DATA_DIR=/data/piri
TEMP_DIR=/tmp/piri
CONFIG_FILE="$DATA_DIR/piri-config.toml"
BASE_CONFIG_SNAPSHOT="$DATA_DIR/piri-base-config.applied.toml"
# A digest of the inputs that reach init only as flags, so a changed chain
# endpoint, public URL or database password re-runs init too. Hashed because the
# DSN carries the Postgres password and this file sits on the data volume.
INIT_INPUTS_SNAPSHOT="$DATA_DIR/piri-init-inputs.applied.sha256"

: "${LOTUS_ENDPOINT:?LOTUS_ENDPOINT must be set}"
: "${PUBLIC_URL:?PUBLIC_URL must be set}"
: "${REGISTRAR_URL:?REGISTRAR_URL must be set}"
# Passed to both init and serve, so a run that skips init still serves against
# the current directory. `piri init` ignores a `[ucan] plc_directory` in the
# base config, so the flag is the only way into init.
: "${PLC_DIRECTORY_URL:?PLC_DIRECTORY_URL must be set}"
: "${OPERATOR_EMAIL:?OPERATOR_EMAIL must be set}"
: "${PIRI_DB_POSTGRES_URL:?PIRI_DB_POSTGRES_URL must be set}"
PORT="${PORT:-3000}"
HOST="${HOST:-0.0.0.0}"

init_inputs_digest() {
  command -v sha256sum >/dev/null ||
    { echo "ERROR: this image has no sha256sum" >&2; exit 1; }
  printf '%s\n' \
    "lotus-endpoint=$LOTUS_ENDPOINT" \
    "public-url=$PUBLIC_URL" \
    "port=$PORT" \
    "host=$HOST" \
    "operator-email=$OPERATOR_EMAIL" \
    "registrar-url=$REGISTRAR_URL" \
    "plc-directory=$PLC_DIRECTORY_URL" \
    "db-postgres-url=$PIRI_DB_POSTGRES_URL" |
    sha256sum | cut -d' ' -f1
}

mkdir -p "$DATA_DIR" "$TEMP_DIR"

# A node that predates the digest snapshot has no file to compare against and
# re-runs init once. That is safe: init reuses an existing registration and
# proof set, and only re-merges the config.
INIT_INPUTS="$(init_inputs_digest)"
if [ -f "$CONFIG_FILE" ] && grep -q proof_set "$CONFIG_FILE" 2>/dev/null &&
   cmp -s "$BASE_CONFIG" "$BASE_CONFIG_SNAPSHOT" &&
   [ "$INIT_INPUTS" = "$(cat "$INIT_INPUTS_SNAPSHOT" 2>/dev/null)" ]; then
  echo "Piri config exists and is current"
else
  cd "$DATA_DIR"
  /usr/bin/piri init \
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
    --db-postgres-url="$PIRI_DB_POSTGRES_URL" >/dev/null
  cp "$BASE_CONFIG" "$BASE_CONFIG_SNAPSHOT"
  printf '%s\n' "$INIT_INPUTS" >"$INIT_INPUTS_SNAPSHOT"
fi

exec /usr/bin/piri serve full --config "$CONFIG_FILE" \
  --plc-directory="$PLC_DIRECTORY_URL"
