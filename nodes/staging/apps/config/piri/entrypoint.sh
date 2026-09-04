#!/bin/sh
set -e

KEY_FILE=/keys/piri.pem
WALLET_FILE=/keys/owner-wallet.hex
BASE_CONFIG=/config/piri-base-config.toml
DATA_DIR=/data/piri
TEMP_DIR=/tmp/piri
CONFIG_FILE="$DATA_DIR/piri-config.toml"
BASE_CONFIG_SNAPSHOT="$DATA_DIR/piri-base-config.applied.toml"

: "${LOTUS_ENDPOINT:?LOTUS_ENDPOINT must be set}"
: "${PUBLIC_URL:?PUBLIC_URL must be set}"
: "${REGISTRAR_URL:?REGISTRAR_URL must be set}"
: "${OPERATOR_EMAIL:?OPERATOR_EMAIL must be set}"

mkdir -p "$DATA_DIR" "$TEMP_DIR"

if [ -f "$CONFIG_FILE" ] && grep -q proof_set "$CONFIG_FILE" 2>/dev/null &&
   cmp -s "$BASE_CONFIG" "$BASE_CONFIG_SNAPSHOT"; then
  echo "Piri config exists and is current"
else
  cd "$DATA_DIR"
  /usr/bin/piri init \
    --base-config="$BASE_CONFIG" \
    --registrar-url="$REGISTRAR_URL" \
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
    --db-postgres-url="${PIRI_DB_POSTGRES_URL:?PIRI_DB_POSTGRES_URL must be set}" >/dev/null
  cp "$BASE_CONFIG" "$BASE_CONFIG_SNAPSHOT"
fi

exec /usr/bin/piri serve full --config "$CONFIG_FILE"
