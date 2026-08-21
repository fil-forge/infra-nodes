#!/usr/bin/env bash
# Shared helpers for the scripts that run on a FilOne Appliance node.
#
# Sourced, never executed. Everything here assumes root on the node: the secrets
# tmpfs is 0700 root, the seal token file is 0400 root, and the docker socket is
# root's.

# shellcheck shell=bash

FILONE_CONTROL_DIR=/mnt/filone/control
FILONE_SECRETS_DIR=/run/filone/secrets
FILONE_STATE_DIR="$FILONE_CONTROL_DIR/state"
FILONE_METRICS_DIR="$FILONE_CONTROL_DIR/state/metrics"
FILONE_SEAL_TOKEN_FILE=/etc/filone/seal-token
FILONE_BAO_TOKEN_FILE=/etc/filone/bao-token
FILONE_BAO_CONTAINER=filone-openbao

# Where this node's secrets live in the local OpenBao. One KV v2 mount, one
# path per subject, so a policy can be written per subject later without moving
# anything.
FILONE_BAO_MOUNT=filone

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Load /etc/filone/node.conf and the node's own node.env, and check that the box
# agrees with the checkout about which node it is. A node running another node's
# configuration would render another node's hostnames into its certificates and
# register the wrong URL with sprue, so this is worth failing on.
filone_init() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"

  [ -r /etc/filone/node.conf ] || die "/etc/filone/node.conf is missing; cloud-init did not finish"
  # shellcheck disable=SC1091
  . /etc/filone/node.conf

  : "${FILONE_NODE:?FILONE_NODE not set in /etc/filone/node.conf}"
  : "${FILONE_CHECKOUT:?FILONE_CHECKOUT not set in /etc/filone/node.conf}"

  FILONE_NODE_DIR="$FILONE_CHECKOUT/nodes/$FILONE_NODE"
  [ -d "$FILONE_NODE_DIR" ] || die "no directory for node '$FILONE_NODE' at $FILONE_NODE_DIR"

  local host_node="$FILONE_NODE"
  set -a
  # shellcheck disable=SC1091
  . "$FILONE_NODE_DIR/node.env"
  set +a
  [ "$FILONE_NODE" = "$host_node" ] ||
    die "node.env says node '$FILONE_NODE' but this box is '$host_node'"

  mkdir -p "$FILONE_STATE_DIR" "$FILONE_METRICS_DIR"
  install -d -m 0700 -o root -g root "$FILONE_SECRETS_DIR"

  # When this run started. wait_healthy uses it to tell a container that
  # crash-looped just now from one that restarted at some point in the past.
  FILONE_DEPLOY_START="$(date +%s)"
}

# --- OpenBao ---------------------------------------------------------------

# Run the bao CLI inside the OpenBao container. The container publishes no port
# and its listener is on loopback, so `docker exec` is the only way in and the
# API is unreachable from anywhere but this box.
bao() {
  local token
  token="$(cat "$FILONE_BAO_TOKEN_FILE" 2>/dev/null || true)"
  [ -n "${token:-${BAO_TOKEN:-}}" ] || die "no OpenBao token; run provision-platform.sh first"

  docker exec -i \
    -e "BAO_ADDR=http://127.0.0.1:8200" \
    -e "BAO_TOKEN=${BAO_TOKEN:-$token}" \
    "$FILONE_BAO_CONTAINER" bao "$@"
}

# Put the seal token where compose can interpolate it, and make sure the file
# holding the rest exists. Compose refuses to start when a named --env-file is
# missing, and on a first run the rest cannot exist yet: it is read out of the
# OpenBao this token is about to unseal.
write_openbao_env() {
  [ -r "$FILONE_SEAL_TOKEN_FILE" ] ||
    die "no seal token at $FILONE_SEAL_TOKEN_FILE; run provision-platform.sh"

  write_secret_file "$FILONE_SECRETS_DIR/openbao.env" \
    "SEAL_TOKEN=$(cat "$FILONE_SEAL_TOKEN_FILE")
" || true

  [ -f "$FILONE_SECRETS_DIR/platform.env" ] ||
    install -m 0400 /dev/null "$FILONE_SECRETS_DIR/platform.env"
}

bao_is_unsealed() {
  # `bao status` exits 0 unsealed, 2 sealed, 1 unreachable, and needs no token.
  docker exec -i -e "BAO_ADDR=http://127.0.0.1:8200" "$FILONE_BAO_CONTAINER" \
    bao status >/dev/null 2>&1
}

# Read one field. Missing paths and missing fields both fail loudly rather than
# rendering an empty string into a config file.
bao_get() {
  local path="$1" field="$2" value
  value="$(bao kv get -mount="$FILONE_BAO_MOUNT" -field="$field" "$path" 2>/dev/null)" ||
    die "OpenBao has no $FILONE_BAO_MOUNT/$path#$field"
  [ -n "$value" ] || die "OpenBao returned an empty value for $FILONE_BAO_MOUNT/$path#$field"
  printf '%s' "$value"
}

bao_has() {
  bao kv get -mount="$FILONE_BAO_MOUNT" -field="$2" "$1" >/dev/null 2>&1
}

# Write a field only if it is not already there. Key generation runs on every
# provision, and a second run must not mint a new identity for a node that is
# already registered with central.
bao_put_if_absent() {
  local path="$1" field="$2" value="$3"
  if bao_has "$path" "$field"; then
    echo "  $path#$field already set, keeping it"
    return 0
  fi
  bao kv patch -mount="$FILONE_BAO_MOUNT" "$path" "$field=-" <<<"$value" >/dev/null ||
    bao kv put -mount="$FILONE_BAO_MOUNT" "$path" "$field=-" <<<"$value" >/dev/null
  echo "  $path#$field written"
}

# --- Rendering -------------------------------------------------------------

# Substitute ${NAME} in a template from the environment, writing the result into
# the secrets tmpfs at 0400 root.
#
# Python rather than envsubst (not installed) or an eval'd heredoc (which would
# let a `$(...)` inside a secret run as root). Only the exact form ${NAME} is
# replaced; a bare $ is left alone, and a name with no value in the environment
# is an error rather than an empty string, because an empty password renders a
# config that starts and then fails somewhere far away.
render_template() {
  local template="$1" destination="$2" tmp
  [ -r "$template" ] || die "no template at $template"

  tmp="$(mktemp "$FILONE_SECRETS_DIR/.render.XXXXXX")"
  chmod 0400 "$tmp"

  if ! python3 -c '
import os, re, sys

template, destination = sys.argv[1], sys.argv[2]
missing = []

def substitute(match):
    name = match.group(1)
    if name not in os.environ:
        missing.append(name)
        return ""
    return os.environ[name]

with open(template) as handle:
    rendered = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", substitute, handle.read())

if missing:
    sys.exit("unset in the environment: " + ", ".join(sorted(set(missing))))

with open(destination, "w") as handle:
    handle.write(rendered)
' "$template" "$tmp"; then
    rm -f "$tmp"
    die "rendering $template failed"
  fi

  # Compare before replacing, so the caller can restart only what changed.
  if [ -f "$destination" ] && cmp -s "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$destination"
  chmod 0400 "$destination"
  return 0
}

# Write a literal secret into the tmpfs, same 0400 and same changed/unchanged
# answer as render_template.
write_secret_file() {
  local destination="$1" content="$2" tmp
  tmp="$(mktemp "$FILONE_SECRETS_DIR/.write.XXXXXX")"
  chmod 0400 "$tmp"
  printf '%s' "$content" >"$tmp"

  if [ -f "$destination" ] && cmp -s "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$destination"
  chmod 0400 "$destination"
  return 0
}

# Piri's --wallet-file is not a private key. It is a hex-encoded Filecoin
# keystore record, {"Type":"delegated","PrivateKey":"<base64 raw key>"}, hex
# again on the outside — piri reads the file, hex-decodes it and unmarshals the
# JSON. OpenBao holds the bare key, so the wrapping happens here.
piri_wallet_hex() {
  local raw_key="$1"
  python3 -c '
import base64, binascii, json, sys

raw = binascii.unhexlify(sys.argv[1])
record = json.dumps({"Type": "delegated", "PrivateKey": base64.b64encode(raw).decode()},
                    separators=(",", ":"))
sys.stdout.write(binascii.hexlify(record.encode()).decode())
' "$raw_key"
}

# --- Compose ---------------------------------------------------------------

# The seal token is in an env file of its own because of the order things come
# up in: OpenBao needs it before OpenBao can answer, and everything in
# platform.env is read out of OpenBao.
compose_platform() {
  docker compose \
    --project-directory "$FILONE_NODE_DIR/platform" \
    -p filone-platform \
    --env-file "$FILONE_NODE_DIR/node.env" \
    --env-file "$FILONE_NODE_DIR/platform/versions.env" \
    --env-file "$FILONE_SECRETS_DIR/openbao.env" \
    --env-file "$FILONE_SECRETS_DIR/platform.env" \
    "$@"
}

compose_apps() {
  docker compose \
    --project-directory "$FILONE_NODE_DIR/apps" \
    -p filone-apps \
    --env-file "$FILONE_NODE_DIR/node.env" \
    --env-file "$FILONE_NODE_DIR/apps/versions.env" \
    --env-file "$FILONE_SECRETS_DIR/apps.env" \
    "$@"
}

# --- Health ----------------------------------------------------------------

# Wait until every container in a compose project is ready, or fail.
#
# Ported from smelt's staging deploy, including the two races it encodes. A
# crash-looping container oscillates faster than this polls, so a single
# `compose ps` snapshot can catch it mid-restart and read it as running:
# RestartCount from `docker inspect` is the non-racy signal, read together with
# StartedAt so an old restart is not mistaken for a crash loop now. And a
# service that comes up clean and dies two seconds later would pass a single
# poll, so the whole project has to read ready twice in a row, at least one
# sleep apart.
#
# Usage: wait_healthy <compose function name> [timeout seconds]
wait_healthy() {
  local compose_fn="$1" timeout="${2:-300}" deadline ready_streak=0
  deadline=$(( $(date +%s) + timeout ))

  echo "==> waiting for health (timeout ${timeout}s)"
  while :; do
    local bad=0 pending=0 name status health restarts exitcode started_at started_epoch

    while IFS='|' read -r name status health restarts exitcode started_at; do
      name="${name#/}"
      started_epoch="$(date -d "$started_at" +%s 2>/dev/null || echo 0)"
      case "$status" in
        running)
          # RestartCount is cumulative over a container's whole life, so one old
          # restart would otherwise fail every deploy from here on. Only a
          # restart since this run began says anything about what this run did.
          if [ "$restarts" -gt 0 ] && [ "$started_epoch" -ge "$FILONE_DEPLOY_START" ]; then
            echo "  crash-looping (restarts=$restarts): $name"; bad=$((bad + 1))
          else
            case "$health" in
              starting) pending=$((pending + 1)) ;;
              unhealthy) echo "  unhealthy: $name"; bad=$((bad + 1)) ;;
            esac
          fi
          ;;
        restarting)
          echo "  restarting (restarts=$restarts): $name"; bad=$((bad + 1)) ;;
        exited)
          # One-shot containers are fine once they exit 0.
          [ "$exitcode" = "0" ] || { echo "  exited ($exitcode): $name"; bad=$((bad + 1)); } ;;
        dead)
          echo "  dead: $name"; bad=$((bad + 1)) ;;
        *)
          pending=$((pending + 1)) ;;
      esac
    done < <(docker inspect \
      -f '{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.ExitCode}}|{{.State.StartedAt}}' \
      $("$compose_fn" ps -aq))

    if [ "$bad" -gt 0 ]; then
      "$compose_fn" ps -a
      die "$bad service(s) crash-looping, dead or unhealthy"
    fi

    if [ "$pending" -eq 0 ]; then
      ready_streak=$((ready_streak + 1))
      [ "$ready_streak" -ge 2 ] && { echo "  all services healthy"; return 0; }
    else
      ready_streak=0
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      "$compose_fn" ps -a
      die "timed out waiting for health"
    fi
    sleep 5
  done
}

# --- Metrics ---------------------------------------------------------------

# Stamp a successful deploy for Alloy's textfile collector to scrape. The metric
# a deadman alert watches: a node that stops deploying, stops reconciling or
# stops running at all goes stale here, which no per-deploy alert can see.
#
# Each project keeps a timestamp next door and the whole .prom file is rewritten
# from all of them. One family per file: the textfile collector concatenates
# what it finds, and the same metric name declared in two files is a parse error
# that takes every metric on the node down with it.
stamp_deploy_success() {
  local project="$1" tmp stamp
  mkdir -p "$FILONE_METRICS_DIR" "$FILONE_STATE_DIR/deploys"
  date +%s >"$FILONE_STATE_DIR/deploys/$project"

  tmp="$(mktemp "$FILONE_METRICS_DIR/.deploy.XXXXXX")"
  {
    echo "# HELP deploy_last_success_timestamp Unix time of the last successful deploy."
    echo "# TYPE deploy_last_success_timestamp gauge"
    for stamp in "$FILONE_STATE_DIR"/deploys/*; do
      [ -f "$stamp" ] || continue
      echo "deploy_last_success_timestamp{project=\"$(basename "$stamp")\"} $(cat "$stamp")"
    done
  } >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$FILONE_METRICS_DIR/deploy.prom"
}
