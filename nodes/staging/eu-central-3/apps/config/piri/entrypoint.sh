#!/bin/sh
set -e

KEY_FILE=/keys/piri.pem
WALLET_FILE=/keys/owner-wallet.hex
BASE_CONFIG=/config/piri-base-config.toml
DATA_DIR=/data/piri
TEMP_DIR=/tmp/piri
CONFIG_FILE="$DATA_DIR/piri-config.toml"
# `piri init` writes piri-config.toml into its working directory, and the
# file holds the chain RPC token. Init runs in this tmpfs, so the token never
# reaches the data disk; only a copy without it does.
INIT_DIR=/run/piri-init
BASE_CONFIG_SNAPSHOT="$DATA_DIR/piri-base-config.applied.toml"

: "${PIRI_PDP_LOTUS_ENDPOINT:?PIRI_PDP_LOTUS_ENDPOINT must be set}"
: "${PIRI_PDP_LOTUS_AUTH_TOKEN:?PIRI_PDP_LOTUS_AUTH_TOKEN must be set}"
: "${PUBLIC_URL:?PUBLIC_URL must be set}"
: "${REGISTRAR_URL:?REGISTRAR_URL must be set}"
# Passed to both init and serve: init only re-runs when the base config
# changes, and `piri init` ignores a `[ucan] plc_directory` in the base config.
: "${PLC_DIRECTORY_URL:?PLC_DIRECTORY_URL must be set}"
: "${OPERATOR_EMAIL:?OPERATOR_EMAIL must be set}"

mkdir -p "$DATA_DIR" "$TEMP_DIR"

if [ -f "$CONFIG_FILE" ] && grep -q proof_set "$CONFIG_FILE" 2>/dev/null &&
   cmp -s "$BASE_CONFIG" "$BASE_CONFIG_SNAPSHOT"; then
  echo "Piri config exists and is current"
else
  grep -q " $INIT_DIR tmpfs " /proc/mounts ||
    { echo "ERROR: $INIT_DIR is not a tmpfs; init would write the chain RPC token to disk" >&2; exit 1; }
  cd "$INIT_DIR"
  rm -f piri-config.toml
  /usr/bin/piri init \
    --base-config="$BASE_CONFIG" \
    --registrar-url="$REGISTRAR_URL" \
    --plc-directory="$PLC_DIRECTORY_URL" \
    --data-dir="$DATA_DIR" \
    --temp-dir="$TEMP_DIR" \
    --key-file="$KEY_FILE" \
    --wallet-file="$WALLET_FILE" \
    --lotus-endpoint="$PIRI_PDP_LOTUS_ENDPOINT" \
    --public-url="$PUBLIC_URL" \
    --port="${PORT:-3000}" \
    --host="${HOST:-0.0.0.0}" \
    --operator-email="$OPERATOR_EMAIL" \
    --db-type=postgres \
    --db-postgres-url="${PIRI_DB_POSTGRES_URL:?PIRI_DB_POSTGRES_URL must be set}" >/dev/null
  # init falls back to stdout, which goes to /dev/null, when it cannot create
  # the file, and still exits 0.
  [ -s piri-config.toml ] ||
    { echo "ERROR: piri init wrote no piri-config.toml" >&2; exit 1; }
  # `serve` reads the token from the environment. The rename keeps a crash
  # from leaving half a config on the disk.
  grep -v '^[[:space:]]*lotus_auth_token[[:space:]]*=' piri-config.toml >"$CONFIG_FILE.new"
  mv "$CONFIG_FILE.new" "$CONFIG_FILE"
  rm -f piri-config.toml
  cp "$BASE_CONFIG" "$BASE_CONFIG_SNAPSHOT"
fi

exec /usr/bin/piri serve full --config "$CONFIG_FILE" \
  --plc-directory="$PLC_DIRECTORY_URL"
