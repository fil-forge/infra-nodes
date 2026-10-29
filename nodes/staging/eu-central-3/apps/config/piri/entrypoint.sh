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
# binary's hash, config version and inputs hash attempted. While all three
# match, later starts skip init; see the dev entrypoint.
INIT_FAILED="$DATA_DIR/piri-init.failed"
# The config as it was before a re-run of init; see the dev entrypoint.
CONFIG_BEFORE="$DATA_DIR/piri-config.toml.before-init"

# The proof set IDs a config names, sorted and on one line; empty if none.
proof_sets() {
  sed -n 's/^[[:space:]]*proof_set[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$1" 2>/dev/null |
    sort -u | tr '\n' ' '
}

# A re-run of init is killed after this long and the existing config served.
# KILL, because piri catches SIGTERM and init does not stop on it.
INIT_TIMEOUT="${PIRI_INIT_TIMEOUT-300}"
case "$INIT_TIMEOUT" in
  ""|*[!0-9]*|0*)
    echo "WARNING: PIRI_INIT_TIMEOUT='$INIT_TIMEOUT' is not a whole number of seconds without leading zeros; using 300" >&2
    INIT_TIMEOUT=300 ;;
esac
# `piri init` writes piri-config.toml into its working directory, and the
# file holds the chain RPC token. Init runs in this tmpfs, so the token never
# reaches the data disk; only a copy without it does.
INIT_DIR=/run/piri-init

: "${PIRI_PDP_LOTUS_ENDPOINT:?PIRI_PDP_LOTUS_ENDPOINT must be set}"
: "${PIRI_PDP_LOTUS_AUTH_TOKEN:?PIRI_PDP_LOTUS_AUTH_TOKEN must be set}"
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
  --lotus-endpoint="$PIRI_PDP_LOTUS_ENDPOINT" \
  --public-url="$PUBLIC_URL" \
  --port="${PORT:-3000}" \
  --host="${HOST:-0.0.0.0}" \
  --operator-email="$OPERATOR_EMAIL" \
  --db-type=postgres \
  --db-postgres-url="${PIRI_DB_POSTGRES_URL:?PIRI_DB_POSTGRES_URL must be set}"
# Key and wallet contents are deliberately left out: init run with a different
# wallet could create a new proof set on chain as a side effect of a restart.
INPUTS=$( { cat "$BASE_CONFIG"; printf '%s\n' "$@"; } | sha256sum | cut -d' ' -f1)

# A copy left by a re-run that never finished goes back first; see the dev
# entrypoint.
if [ -f "$CONFIG_BEFORE" ]; then
  echo "WARNING: restoring the config from before an init that did not finish" >&2
  mv -f "$CONFIG_BEFORE" "$CONFIG_FILE" || {
    echo "ERROR: could not restore $CONFIG_FILE from $CONFIG_BEFORE; not serving the config an unfinished init left" >&2
    exit 1
  }
fi

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
  rm -f "$INIT_FAILED" 2>/dev/null || true
elif [ "$REASON" != "no config yet" ] && [ "$(cat "$INIT_FAILED" 2>/dev/null)" = "$ATTEMPT" ]; then
  echo "WARNING: skipping init: it already failed for this Piri and these inputs; serving the existing config version $HAVE_VERSION. docs/RUNBOOK.md says how to retry" >&2
else
  case "$REASON" in
    version) echo "Running piri init: this Piri writes config version $WANT_VERSION, the config on disk is $HAVE_VERSION" ;;
    migration) echo "Running piri init once to write its stamp" ;;
    *) echo "Running piri init: $REASON" ;;
  esac
  grep -q " $INIT_DIR tmpfs " /proc/mounts ||
    { echo "ERROR: $INIT_DIR is not a tmpfs; init would write the chain RPC token to disk" >&2; exit 1; }
  # init writes into the tmpfs; its output replaces CONFIG_FILE once it
  # returns, and the check below puts the copy back after a failed re-run.
  cd "$INIT_DIR"
  rm -f piri-config.toml
  # Only a re-run is bounded: a first init has no config to fall back to.
  if [ "$REASON" != "no config yet" ]; then
    set -- timeout -s KILL "$INIT_TIMEOUT" "$@"
  fi
  # On a re-run, the proof set the node has been proving, for the check after
  # init; see the dev entrypoint for why.
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
  INIT_STATUS=0
  if [ -n "$INIT_SKIPPED" ]; then
    INIT_STATUS=1
  else
    "$@" >/dev/null || INIT_STATUS=$?
  fi
  # `serve` reads the token from the environment, so CONFIG_FILE gets init's
  # config without it; the rename keeps a crash from leaving half a config on
  # the disk. On a re-run it goes there even after a failure, so the proof set
  # check below sees a proof set that run created; a failed first run has no
  # copy to go back to, so its output is not installed. init falls back to
  # stdout, which goes to /dev/null, when it cannot create the file, and still
  # exits 0: a failed run.
  if [ -s piri-config.toml ] && { [ "$INIT_STATUS" -eq 0 ] || [ -f "$CONFIG_BEFORE" ]; }; then
    if ! { grep -v '^[[:space:]]*lotus_auth_token[[:space:]]*=' piri-config.toml >"$CONFIG_FILE.new" &&
           mv "$CONFIG_FILE.new" "$CONFIG_FILE"; }; then
      echo "ERROR: could not write $CONFIG_FILE from init's output" >&2
      rm -f "$CONFIG_FILE.new" 2>/dev/null || true
      INIT_STATUS=1
    fi
  elif [ "$INIT_STATUS" -eq 0 ]; then
    echo "ERROR: piri init wrote no piri-config.toml" >&2
    INIT_STATUS=1
  fi
  rm -f piri-config.toml 2>/dev/null || true
  # 124 or 137: the timeout killed it.
  INIT_TIMED_OUT=""
  if [ "$REASON" != "no config yet" ]; then
    case "$INIT_STATUS" in 124|137) INIT_TIMED_OUT=1 ;; esac
  fi
  # A config naming a different proof set means init created or adopted one;
  # put the old config back and serve it. The copy also goes back after any run
  # that did not succeed, or that exited 0 leaving no proof set, and such a run
  # is not a success. See the dev entrypoint.
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
  elif { [ "$REASON" = "version" ] || [ "$REASON" = "migration" ] || [ -n "$INIT_TIMED_OUT" ]; } &&
       grep -q proof_set "$CONFIG_FILE" 2>/dev/null; then
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

# A config served without a successful init, or written before init ran in the
# tmpfs, may still hold the chain RPC token.
if grep -q '^[[:space:]]*lotus_auth_token[[:space:]]*=' "$CONFIG_FILE"; then
  echo "Removing the chain RPC token an older init left in the config"
  sed -i '/^[[:space:]]*lotus_auth_token[[:space:]]*=/d' "$CONFIG_FILE"
fi

exec /usr/bin/piri serve full --config "$CONFIG_FILE" \
  --plc-directory="$PLC_DIRECTORY_URL"
