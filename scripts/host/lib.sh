#!/usr/bin/env bash
# Shared helpers for the scripts that run on a FilOne Appliance node.
#
# Sourced, never executed. Everything here assumes root on the node: the secrets
# tmpfs is 0700 root, the seal token file is 0400 root, and the docker socket is
# root's.

# shellcheck shell=bash
# SC2154: filone_init reads /etc/fil-one/node.conf and the node's node.env, so
# the variables from both are assigned at run time, in files no static check
# can see.
# shellcheck disable=SC2154

FILONE_CONTROL_DIR=/mnt/fil-one/control
# SC2034: provision-apps.sh uses this after sourcing the library.
# shellcheck disable=SC2034
FILONE_DATA_DIR=/mnt/fil-one/data
FILONE_SECRETS_DIR=/run/fil-one/secrets
FILONE_SEAL_TOKEN_FILE=/etc/fil-one/seal-token
FILONE_BAO_TOKEN_FILE=/etc/fil-one/bao-token
FILONE_BAO_CONTAINER=filone-openbao

# The bind mount OpenBao's unix listener puts its API socket on, and Ingot
# mounts to reach it. Created root-owned, like the secrets tmpfs: OpenBao's
# entrypoint chowns it to the user the server drops to before that drop
# happens, which is the same thing that makes the raft mount writable.
FILONE_BAO_SOCKET_DIR=/run/fil-one/bao

# Where this node's secrets live in the local OpenBao. One KV v2 mount, one
# path per subject, so a policy can be written per subject later without moving
# anything.
FILONE_BAO_MOUNT=filone

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Load /etc/fil-one/node.conf and the node's own node.env, and check that the box
# agrees with the checkout about which node it is. A node running another node's
# configuration would render another node's hostnames into its certificates and
# register the wrong URL with sprue, so this is worth failing on.
filone_init() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"

  [ -r /etc/fil-one/node.conf ] || die "/etc/fil-one/node.conf is missing; cloud-init did not finish"
  # shellcheck disable=SC1091
  . /etc/fil-one/node.conf

  : "${FILONE_NODE:?FILONE_NODE not set in /etc/fil-one/node.conf}"
  : "${FILONE_CHECKOUT:?FILONE_CHECKOUT not set in /etc/fil-one/node.conf}"

  FILONE_NODE_DIR="$FILONE_CHECKOUT/nodes/$FILONE_NODE"
  [ -d "$FILONE_NODE_DIR" ] || die "no directory for node '$FILONE_NODE' at $FILONE_NODE_DIR"

  local host_node="$FILONE_NODE"
  set -a
  # shellcheck disable=SC1091
  . "$FILONE_NODE_DIR/node.env"
  set +a
  [ "$FILONE_NODE" = "$host_node" ] ||
    die "node.env says node '$FILONE_NODE' but this box is '$host_node'"

  FILONE_STATE_DIR="$FILONE_CONTROL_DIR/state"
  FILONE_METRICS_DIR="$FILONE_STATE_DIR/metrics"
  FILONE_REVISIONS_DIR="$FILONE_STATE_DIR/revisions"

  mkdir -p "$FILONE_STATE_DIR" "$FILONE_METRICS_DIR"
  install -d -m 0700 -o root -g root "$FILONE_SECRETS_DIR"
  # cloud-init creates this too, so on a fresh node it is already there. Here as
  # well, so a node provisioned before the socket existed gets the directory on
  # its next deploy rather than on a re-bootstrap.
  install -d -m 0700 -o root -g root "$FILONE_BAO_SOCKET_DIR"

  # Ingot's region KEK, in this node's own transit engine. Derived from the one
  # statement of the region string rather than committed a second time, so a
  # node that is renamed cannot end up wrapping under a key named for the old
  # region while its config asks for the new one.
  FILONE_REGIONKEY_NAME="region-$REGION_LABEL"

  # When this run started. wait_healthy uses it to tell a container that
  # crash-looped just now from one that restarted at some point in the past.
  FILONE_DEPLOY_START="$(date +%s)"
}

# Fail on a node.env value that is still the placeholder it was committed with.
#
# Some values cannot be known until the account they name exists, so they are
# committed as an obviously-wrong string. Nothing downstream rejects them: a
# Grafana push with user id 000000 is refused by Grafana and Alloy keeps
# running, so without this the deploy stamps success while the node is invisible.
require_configured() {
  local name="$1" placeholder="$2"
  [ "${!name}" != "$placeholder" ] ||
    die "$name is still the placeholder $placeholder; set it in $FILONE_NODE_DIR/node.env"
}

# --- systemd ---------------------------------------------------------------

# The service unit this process is running inside, or nothing when it was
# started from a shell. Read from the cgroup, which is where systemd records it
# and the one answer that stays right through a re-exec.
current_service_unit() {
  local cgroup
  cgroup="$(tail -1 /proc/self/cgroup 2>/dev/null || true)"
  [[ "$cgroup" =~ /([^/[:space:]]+\.service) ]] || return 0
  printf '%s' "${BASH_REMATCH[1]}"
}

# Install the checkout's units into /etc/systemd/system and remove the ones the
# checkout no longer has. Called by every reconcile pass and by provisioning,
# which needs the units on the box before the operator can enable the timers.
#
# Against the whole directory rather than against the diff. A unit
# deleted or renamed in the checkout has to leave /etc/systemd/system too:
# daemon-reload leaves an orphan installed, and an orphan that was enabled goes
# on running a workflow git no longer contains.
sync_systemd_units() {
  local unit name wanted="" changed=0
  local self_unit
  self_unit="$(current_service_unit)"

  shopt -s nullglob
  for unit in "$FILONE_CHECKOUT"/systemd/filone-*.service "$FILONE_CHECKOUT"/systemd/filone-*.timer; do
    name="$(basename "$unit")"
    wanted+="$name"$'\n'
    cmp -s "$unit" "/etc/systemd/system/$name" && continue
    install -m 0644 "$unit" "/etc/systemd/system/$name"
    echo "  installed $name"
    changed=1
  done

  # Only this project's units. Anything else in /etc/systemd/system belongs to
  # the distribution or to whoever put it there, and is none of our business.
  #
  # Timers before services, because a service stopped while its timer is still
  # enabled gets started again on the timer's next tick.
  for unit in /etc/systemd/system/filone-*.timer /etc/systemd/system/filone-*.service; do
    name="$(basename "$unit")"
    grep -qxF "$name" <<<"$wanted" && continue
    echo "  removing $name, which the checkout no longer has"
    if [ "$name" = "$self_unit" ]; then
      # The caller is running inside that unit, and `--now` would stop it here,
      # before the removal, the daemon-reload and the rest of the run ever
      # happen. Disabling is enough: the unit goes when this run ends.
      echo "    it is the unit this run is inside, so it is disabled and left to exit"
      systemctl disable "$name" >/dev/null 2>&1 || true
    else
      systemctl disable --now "$name" >/dev/null 2>&1 || true
    fi
    rm -f "$unit"
    changed=1
  done
  shopt -u nullglob

  [ "$changed" -eq 0 ] || systemctl daemon-reload
}

# --- Serialising deploys ---------------------------------------------------

# One lock for the checkout and every deploy entry point. The reconcile timer
# resets the checkout while an operator may be part-way through a manual deploy,
# and that reset replaces the very scripts and rendered configuration the manual
# run is reading: it would finish having run a mixture of two revisions and then
# record whichever HEAD won the race as the one it deployed.
#
# The wait is long because a deploy waiting on Piri's proving window legitimately
# takes most of an hour. Past that, something is stuck and saying so beats a
# timer that hangs forever.
FILONE_DEPLOY_LOCK_FILE=/run/fil-one/deploy.lock
FILONE_DEPLOY_LOCK_WAIT=3600

# flock does not nest, so a deploy script called by reconcile.sh would wait for
# a lock its own parent holds. The parent exports this instead, and children see
# the lock as already taken because they inherit the descriptor with it.
take_deploy_lock() {
  [ -z "${FILONE_DEPLOY_LOCK_HELD:-}" ] || return 0

  install -d -m 0700 /run/fil-one
  exec 9>"$FILONE_DEPLOY_LOCK_FILE"
  flock -w "$FILONE_DEPLOY_LOCK_WAIT" 9 ||
    die "another deploy has held $FILONE_DEPLOY_LOCK_FILE for ${FILONE_DEPLOY_LOCK_WAIT}s.
       'fuser -v $FILONE_DEPLOY_LOCK_FILE' names the process holding it."
  export FILONE_DEPLOY_LOCK_HELD=1
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

  # write_secret_file returns 1 for "unchanged", which is not a failure. It
  # calls die on an actual write failure, so nothing here has to inspect the
  # status: a `|| true` would also disable errexit inside the function and let
  # a failed mv leave a stale openbao.env behind.
  write_secret_file "$FILONE_SECRETS_DIR/openbao.env" \
    "SEAL_TOKEN=$(cat "$FILONE_SEAL_TOKEN_FILE")
" || [ "$?" -eq 1 ]

  [ -f "$FILONE_SECRETS_DIR/platform.env" ] ||
    install -m 0400 /dev/null "$FILONE_SECRETS_DIR/platform.env"
}

# Where the central OpenBao is, read from the seal stanza in the node's bao.hcl.
# That stanza is the only statement of the address, so nothing here keeps a
# second copy that can disagree with the one OpenBao actually seals against.
#
# Scoped to the stanza rather than to the whole file. `address` appears in the
# listener block too, and that block comes first, so the first match in the file
# is this node's own loopback.
central_seal_addr() {
  local config="$FILONE_NODE_DIR/platform/config/openbao/bao.hcl" value
  value="$(awk '
    /^seal[[:space:]]+"/ { inside = 1; next }
    inside && /^}/       { inside = 0 }
    inside && $1 == "address" && match($0, /"[^"]*"/) {
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  ' "$config")"
  [ -n "$value" ] || die "no address in the seal stanza of $config"
  printf '%s' "$value"
}

bao_is_unsealed() {
  # `bao status` exits 0 unsealed, 2 sealed, 1 unreachable, and needs no token.
  docker exec -i -e "BAO_ADDR=http://127.0.0.1:8200" "$FILONE_BAO_CONTAINER" \
    bao status >/dev/null 2>&1
}

# Renew the node's local deploy token. It is periodic, which means it renews
# forever but only for as long as something calls renew, and nothing on the node
# holds it long enough to: every use is a one-shot `docker exec ... bao` that
# exits when the command does, leaving no client behind to keep a lease alive.
# The seal token works the other way, and the local OpenBao renews that one
# itself through the lifetime watcher on its transit seal.
#
# So this runs on every reconcile pass, including a pass with nothing to deploy.
# Let the period lapse and the next deploy stops at its first secret read.
renew_bao_token() {
  bao token renew >/dev/null ||
    die "could not renew the local OpenBao deploy token"
}

# Renew the token Ingot holds for the region wrap key. Periodic like the deploy
# token, and renewed on the same schedule and for the same reason: Ingot's own
# lifetime watcher is not shipped yet, so nothing inside the running process
# keeps its lease alive.
#
# The read and the renewal use different tokens on purpose. bao() prefers
# BAO_TOKEN over the deploy token file, so the assignment below makes `bao token
# renew` act on the region token, while bao_get above it still runs under the
# deploy token that is allowed to read the secret. Written as two statements
# rather than one prefixed command: a die inside the substitution of a
# `BAO_TOKEN="$(bao_get ...)" bao ...` prefix is swallowed, BAO_TOKEN lands
# empty, and the renewal silently extends the deploy token instead.
renew_ingot_regionkey_token() {
  local token
  bao_has ingot regionkey_token ||
    die "OpenBao has no token for the region wrap key. Run
       scripts/host/provision-regionkey.sh; without it Ingot cannot encrypt or
       decrypt any object."
  token="$(bao_get ingot regionkey_token)"

  BAO_TOKEN="$token" bao token renew >/dev/null ||
    die "could not renew Ingot's region-key token. If it has already lapsed,
       scripts/host/provision-regionkey.sh mints a replacement."
}

# Create the transit engine, the region key, the policy that reaches it and the
# token Ingot holds. Called by provision-platform.sh on a new node and by
# provision-regionkey.sh on one that predates the key; both run it under the
# root token, which is what enabling an engine and writing a policy need.
provision_regionkey() {
  bao secrets enable -path=transit transit >/dev/null 2>&1 ||
    echo "  transit engine already enabled"

  # aes256-gcm96 with derived keys: Ingot passes each object's own context to
  # encrypt and decrypt, so one region key produces a distinct key per object
  # and the ciphertexts cannot be moved between them.
  if bao read "transit/keys/$FILONE_REGIONKEY_NAME" >/dev/null 2>&1; then
    echo "  transit key $FILONE_REGIONKEY_NAME already exists"
  else
    bao write "transit/keys/$FILONE_REGIONKEY_NAME" type=aes256-gcm96 derived=true >/dev/null ||
      die "could not create transit/keys/$FILONE_REGIONKEY_NAME"
    echo "  transit key $FILONE_REGIONKEY_NAME created"
  fi

  # Wrap and unwrap under this one key, and nothing else. Reading the key
  # material is not on the list, so a copy of the token lifted out of Ingot's
  # config wraps and unwraps against this node's OpenBao while it is running and
  # is worth nothing once the node is out of service.
  bao policy write ingot-regionkey - <<POLICY >/dev/null
path "transit/encrypt/$FILONE_REGIONKEY_NAME" {
  capabilities = ["update"]
}
path "transit/decrypt/$FILONE_REGIONKEY_NAME" {
  capabilities = ["update"]
}
POLICY

  # No -no-default-policy: renew-self and lookup-self come from `default`, which
  # is how the deploy token renews as well.
  #
  # Orphan, so revoking the root token later does not take Ingot's writes with
  # it. Periodic, so it renews forever; every reconcile pass renews it, which is
  # every five minutes, because nothing inside the running Ingot keeps its lease
  # alive yet.
  #
  # Minted on every run, unlike everything above it. This script is the path
  # back from a revoked or lapsed token, and a re-run that kept the dead one
  # would report success and leave Ingot unable to write an object.
  local token
  token="$(bao token create -policy=ingot-regionkey -orphan -period=72h -field=token)" ||
    die "could not create the ingot-regionkey token"

  # patch where the path exists, so Ingot's key, DID and hilt proof survive; put
  # where it does not, because patch fails on a missing path and on a new node
  # this runs before keygen creates it. Over stdin either way: on the command
  # line the token would be in the container's argv.
  if bao_path_exists ingot; then
    bao kv patch -mount="$FILONE_BAO_MOUNT" ingot regionkey_token=- <<<"$token" >/dev/null ||
      die "could not write $FILONE_BAO_MOUNT/ingot#regionkey_token"
  else
    bao kv put -mount="$FILONE_BAO_MOUNT" ingot regionkey_token=- <<<"$token" >/dev/null ||
      die "could not create $FILONE_BAO_MOUNT/ingot"
  fi
  unset token
  echo "  ingot#regionkey_token written"
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

bao_path_exists() {
  bao kv get -mount="$FILONE_BAO_MOUNT" "$1" >/dev/null 2>&1
}

# Write one or more field/value pairs, in a single OpenBao write, and only if
# the first field is not already there. Key generation runs on every provision,
# and a second run must not mint a new identity for a node that is already
# registered with central.
#
# The whole group lands or none of it does, because a key and the metadata that
# names it are useless apart. A Piri key written without its DID leaves a node
# that cannot be provisioned and cannot be retried either: the next run finds
# the key, refuses to mint a second identity, and has nothing to derive the DID
# from. The first field is the one that is looked up, so pass the key itself
# first and its metadata after it.
bao_put_if_absent() {
  local path="$1" field="$2"
  shift
  if [ "$#" -lt 2 ] || [ $(( $# % 2 )) -ne 0 ]; then
    die "bao_put_if_absent $path: expected field/value pairs, got $# arguments"
  fi

  if bao_has "$path" "$field"; then
    echo "  $path#$field already set, keeping it"
    return 0
  fi

  bao_write_fields "$path" "$@"
}

# Write one or more field/value pairs unconditionally, overwriting any that are
# already there. For rotating a value bao_put_if_absent would otherwise leave
# alone, such as a delegation whose audience has changed underneath it.
bao_replace_fields() {
  local path="$1"
  shift
  if [ "$#" -lt 2 ] || [ $(( $# % 2 )) -ne 0 ]; then
    die "bao_replace_fields $path: expected field/value pairs, got $# arguments"
  fi

  bao_write_fields "$path" "$@"
}

# The write both functions above share, in a single OpenBao write. The whole
# group lands or none of it does, because a value and the metadata that names
# it are useless apart.
bao_write_fields() {
  local path="$1" fields json
  shift

  json="$(bao_fields_json "$@")" || die "could not encode the fields for $FILONE_BAO_MOUNT/$path"

  # patch adds fields, put replaces the whole data map. Which one is correct
  # depends on whether the path is there at all, so this asks rather than trying
  # patch and falling back: a patch that failed for any other reason would send
  # a put at a populated path and delete every field already on it.
  #
  # The values go in over stdin as one JSON object. On the command line they
  # would be in the container's argv, which every user on the box can read.
  fields="$(bao_field_names "$@")"
  if bao_path_exists "$path"; then
    bao kv patch -mount="$FILONE_BAO_MOUNT" "$path" - <<<"$json" >/dev/null ||
      die "could not add $fields to $FILONE_BAO_MOUNT/$path"
  else
    bao kv put -mount="$FILONE_BAO_MOUNT" "$path" - <<<"$json" >/dev/null ||
      die "could not create $FILONE_BAO_MOUNT/$path"
  fi
  echo "  $path#$fields written"
}

# Encode field/value pairs as a JSON object. The pairs arrive over stdin, NUL
# separated, so no secret is ever an argument to anything.
bao_fields_json() {
  printf '%s\0' "$@" | python3 -c '
import json, sys

parts = sys.stdin.buffer.read().split(b"\0")[:-1]
names, values = parts[0::2], parts[1::2]
json.dump(dict(zip((n.decode() for n in names), (v.decode() for v in values))), sys.stdout)
'
}

bao_field_names() {
  local names=""
  while [ "$#" -gt 0 ]; do
    names="${names:+$names,}$1"
    shift 2
  done
  printf '%s' "$names"
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

  # Every write below is checked by hand. Both of these functions answer
  # "changed?" through their exit status, so callers invoke them in an OR-list,
  # and bash turns errexit off for the whole body of a function called that way.
  # An unchecked mktemp or mv would then be silently ignored and the caller
  # would carry on with a stale or missing file.
  tmp="$(mktemp "$FILONE_SECRETS_DIR/.render.XXXXXX")" || die "mktemp failed in $FILONE_SECRETS_DIR"
  chmod 0400 "$tmp" || die "could not chmod $tmp"

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

  mv "$tmp" "$destination" || die "could not write $destination"
  chmod 0400 "$destination" || die "could not chmod $destination"
  return 0
}

# Write a literal secret into the tmpfs, same 0400 and same changed/unchanged
# answer as render_template, and the same hand-checked writes.
write_secret_file() {
  local destination="$1" content="$2" tmp
  tmp="$(mktemp "$FILONE_SECRETS_DIR/.write.XXXXXX")" || die "mktemp failed in $FILONE_SECRETS_DIR"
  chmod 0400 "$tmp" || die "could not chmod $tmp"
  printf '%s' "$content" >"$tmp" || die "could not write $tmp"

  if [ -f "$destination" ] && cmp -s "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$destination" || die "could not write $destination"
  chmod 0400 "$destination" || die "could not chmod $destination"
  return 0
}

# Piri's --wallet-file is not a private key. It is a hex-encoded Filecoin
# keystore record, {"Type":"delegated","PrivateKey":"<base64 raw key>"}, hex
# again on the outside — piri reads the file, hex-decodes it and unmarshals the
# JSON. OpenBao holds the bare key, so the wrapping happens here.
#
# The key goes in on stdin, not in argv. Another local process can read a root
# process's /proc/<pid>/cmdline, and this runs on every apps deploy.
piri_wallet_hex() {
  local raw_key="$1"
  printf '%s' "$raw_key" | python3 -c '
import base64, binascii, json, sys

raw = binascii.unhexlify(sys.stdin.read().strip())
record = json.dumps({"Type": "delegated", "PrivateKey": base64.b64encode(raw).decode()},
                    separators=(",", ":"))
sys.stdout.write(binascii.hexlify(record.encode()).decode())
'
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

# --- Change detection --------------------------------------------------------

# Set a flag variable when a check reports "changed" by exit status, which
# `set -e` would otherwise read as a failure on every unchanged file.
#
# Usage: mark <flag variable name> <command> [args...]
mark() {
  local -n flag="$1"
  shift
  # shellcheck disable=SC2034 # flag is a nameref; the write lands in the caller
  if "$@"; then flag=1; fi
}

# The project's fully resolved definition, plus the contents of every committed
# file it bind-mounts, hashed together. An edit to node.env changes a service's
# environment or its command without changing any rendered file, and an edit to
# the Caddyfile or to Piri's entrypoint changes neither: compose resolves a bind
# mount to a path and never looks at what is behind it, so a definition-only
# hash reads those edits as no change, the deploy picks --no-recreate, and the
# container keeps serving its old configuration while the hash is recorded as
# applied.
#
# Only bind sources under the node directory are read. That is where the
# committed files live. The rendered secrets on the tmpfs are already covered by
# what render_template and write_secret_file return, and the data volumes are
# not configuration.
#
# With a service name, only that service's definition is hashed; without one,
# the whole project's.
compose_config_hash() {
  local compose_fn="$1" service="${2:-}"
  "$compose_fn" config --format json |
    FILONE_HASH_ROOT="$FILONE_NODE_DIR" python3 -c '
import hashlib, json, os, sys

document = json.load(sys.stdin)
root = os.path.realpath(os.environ["FILONE_HASH_ROOT"]) + os.sep

if len(sys.argv) > 1:
    services = {sys.argv[1]: document["services"][sys.argv[1]]}
    config = services[sys.argv[1]]
else:
    services = document.get("services", {})
    config = document

mounted = {}
for name in sorted(services):
    for volume in services[name].get("volumes") or []:
        if not isinstance(volume, dict) or volume.get("type") != "bind":
            continue
        source = volume.get("source")
        if not source:
            continue
        resolved = os.path.realpath(source)
        if not resolved.startswith(root) or not os.path.isfile(resolved):
            continue
        with open(resolved, "rb") as handle:
            mounted[resolved] = hashlib.sha256(handle.read()).hexdigest()

payload = {"config": config, "mounted": mounted}
print(hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest())
' ${service:+"$service"}
}

# Compare a hash against the one the last successful deploy recorded under this
# name. A name nothing has recorded yet counts as changed.
config_changed() {
  local name="$1" current="$2" previous
  previous="$(cat "$FILONE_STATE_DIR/$name.sha256" 2>/dev/null || true)"
  [ "$current" != "$previous" ]
}

config_hash_record() {
  printf '%s\n' "$2" >"$FILONE_STATE_DIR/$1.sha256"
}

# A moving tag resolving to a new digest is invisible to compose, which compares
# the tag string, so the running image id is compared against the pulled one. A
# service with no container yet counts as different: it has to be created.
image_differs() {
  local compose_fn="$1" service="$2" container image running desired
  container="$("$compose_fn" ps -aq "$service" 2>/dev/null | head -n1)"
  [ -n "$container" ] || return 0

  image="$("$compose_fn" config --format json |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["services"][sys.argv[1]]["image"])' \
      "$service")"
  running="$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || echo none)"
  desired="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || echo unknown)"
  [ "$running" != "$desired" ]
}

# --- Piri and Ingot ----------------------------------------------------------

# The two containers a platform deploy has to take down before it touches
# anything underneath them, and bring back once it is done.
#
# By container name rather than through compose_apps, because the apps project
# takes an --env-file that does not exist until provision-apps.sh has run and
# compose refuses to start without it. A node that has never deployed apps still
# has to be able to deploy the platform.
container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = true ]
}

# Ingot first: it writes through to Piri, so it should not outlive it. Returns
# non-zero when there was nothing to stop, so a caller can tell a node whose apps
# it took down from one that has never deployed them.
stop_apps() {
  local container stopped=1
  for container in filone-ingot filone-piri; do
    if container_running "$container"; then
      echo "  stopping $container"
      docker stop "$container" >/dev/null || die "could not stop $container"
      stopped=0
    fi
  done
  return "$stopped"
}

# Piri first, the same order in reverse: Ingot started against a Piri that is
# still coming up produces a burst of failures for no reason.
start_apps() {
  local container
  for container in filone-piri filone-ingot; do
    if container_exists "$container"; then
      echo "  starting $container"
      docker start "$container" >/dev/null || die "could not start $container"
    fi
  done
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
    local ids inspected

    # Read both commands into variables before the loop. Feeding the loop from
    # a process substitution throws their exit status away, so a docker daemon
    # that went down after `up` would yield no rows, leave bad and pending at
    # zero, and be read as every service healthy.
    ids="$("$compose_fn" ps -aq)" || die "could not list the project's containers"
    [ -n "$ids" ] || die "the project has no containers"
    # shellcheck disable=SC2086
    inspected="$(docker inspect \
      -f '{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.ExitCode}}|{{.State.StartedAt}}' \
      $ids)" || die "could not inspect the project's containers"

    # The unquoted command substitution feeding `docker inspect` below is
    # deliberate: the id list has to split into one argument per container.
    # shellcheck disable=SC2046
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
    done <<<"$inspected"

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
  mkdir -p "$FILONE_METRICS_DIR" "$FILONE_STATE_DIR/deploys" "$FILONE_REVISIONS_DIR"
  date +%s >"$FILONE_STATE_DIR/deploys/$project"

  # Which revision this project was deployed from. reconcile.sh diffs the new
  # checkout against it, so a deploy that failed is retried on the next pass:
  # the checkout HEAD has already moved to the failed commit by then, and
  # diffing against that would report nothing left to do.
  git -C "$FILONE_CHECKOUT" rev-parse HEAD >"$FILONE_REVISIONS_DIR/$project"

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

  publish_node_status
}

# --- The status document ---------------------------------------------------

# Write what this node is running to a file Caddy serves at
# https://<piri hostname>/.well-known/filone-node-status.json.
#
# Nothing else on the node says which commit it reached, so nothing could tell a
# merged image bump from a broken one: the merge happens up to an hour before
# the node applies it. scripts/ci/smoke-test.sh reads both halves from here, and
# they answer different questions.
#
# `reconcile` is the commit the node has reached. Every pass stamps it, whether
# or not it deployed anything, so a merge that touches only CI or docs advances
# it too. That is the entry to wait on after a merge.
#
# `platform` and `apps` are the revision each project was last deployed from,
# which only moves when that project actually deploys. That is the entry the pin
# comparison has to be made against.
#
# The running digests are read off the containers rather than out of
# versions.env, which is the point. A pin the node never applied shows up as a
# mismatch instead of as agreement with itself.
#
# Public and unauthenticated, and it carries nothing else: a commit SHA from a
# public repository and digests of public images.
publish_node_status() {
  local tmp revision_file project revision stamped_at service image_id repo_digest
  local projects='{}' images='{}'

  # Everything stamp_deploy_success has recorded, rather than a list here that
  # would go stale the next time a project or a pass is added.
  for revision_file in "$FILONE_REVISIONS_DIR"/*; do
    [ -f "$revision_file" ] || continue
    project="$(basename "$revision_file")"
    revision="$(cat "$revision_file")"
    [ -n "$revision" ] || continue
    stamped_at=''
    [ -f "$FILONE_STATE_DIR/deploys/$project" ] && stamped_at="$(cat "$FILONE_STATE_DIR/deploys/$project")"
    projects="$(jq -c \
      --arg project "$project" --arg revision "$revision" --arg stamped_at "$stamped_at" \
      '.[$project] = {revision: $revision,
                      stamped_at: ($stamped_at | if . == "" then null else tonumber end)}' \
      <<<"$projects")"
  done

  # Absent rather than fatal when a container is not there. A platform deploy
  # stamps too, and platform is provisioned before apps exist.
  for service in piri ingot; do
    # Two hops: the container carries an image ID, the image carries the
    # repository digest. Empty when the image was never pulled from a registry.
    image_id="$(docker container inspect --format '{{.Image}}' "filone-$service" 2>/dev/null || true)"
    repo_digest=''
    if [ -n "$image_id" ]; then
      repo_digest="$(docker image inspect \
        --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$image_id" 2>/dev/null || true)"
    fi
    images="$(jq -c --arg service "$service" --arg digest "$repo_digest" \
      '.[$service] = (if $digest == "" then null else $digest end)' <<<"$images")"
  done

  # Written aside and moved, as deploy.prom is: Caddy serves this file to the
  # public and must never see a half-written one.
  tmp="$(mktemp "$FILONE_STATE_DIR/.node-status.XXXXXX")"
  jq -n \
    --arg node "$FILONE_NODE" \
    --arg stage "$STAGE" \
    --arg published_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson projects "$projects" \
    --argjson images "$images" \
    '{node: $node, stage: $stage, published_at: $published_at,
      projects: $projects, images: $images}' >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$FILONE_STATE_DIR/filone-node-status.json"
}
