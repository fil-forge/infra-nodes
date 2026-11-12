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

# Whether this node ships its own telemetry, from whether its node.env carries
# the Grafana Cloud endpoints. A node whose host owns Alloy leaves all six out
# and needs no push token; a node that runs Alloy in the platform project has
# all six and does.
#
# All six or none. A node.env missing one of them would otherwise deploy as if
# it shipped nothing, and the operator's first sign of it would be a template
# complaining about GRAFANA_PUSH_TOKEN several steps later.
node_ships_telemetry() {
  local name set_names="" unset_names=""
  for name in GRAFANA_LOGS_URL GRAFANA_LOGS_USER GRAFANA_METRICS_URL GRAFANA_METRICS_USER \
    GRAFANA_TRACES_URL GRAFANA_TRACES_USER; do
    if [ -n "${!name:-}" ]; then
      set_names+=" $name"
    else
      unset_names+=" $name"
    fi
  done

  [ -n "$set_names" ] || return 1
  [ -n "$unset_names" ] &&
    die "$FILONE_NODE_DIR/node.env sets$set_names but not$unset_names.
       Alloy needs all six to push, or none of them for a node whose host ships
       its telemetry instead."
  return 0
}

# Whether this node pushes backups to central, from FILONE_TAKES_BACKUPS in its
# node.env. Where the backups go is not in node.env: central wraps the bucket,
# prefix and AWS region with the access key, and provision-backups.sh stores
# all five at filone/backup-target, so the target and the key that writes there
# cannot disagree.
#
# Every node.env must say true or false. With a default, a node.env that left
# the line out would run as if it took no backups, and nothing would notice
# until a backup was needed.
node_takes_backups() {
  case "${FILONE_TAKES_BACKUPS:-}" in
    true) return 0 ;;
    false) return 1 ;;
    "")
      die "FILONE_TAKES_BACKUPS is not set in $FILONE_NODE_DIR/node.env. Set it to
       true on a node that pushes its backups to central, or false on one that
       takes none." ;;
    *)
      die "FILONE_TAKES_BACKUPS is '$FILONE_TAKES_BACKUPS' in $FILONE_NODE_DIR/node.env;
       it must be true or false." ;;
  esac
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

# shellcheck source=lib/openbao.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/openbao.sh"

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

# --- Postgres ----------------------------------------------------------------

# SC2034: migrate-postgres-to-debian.sh uses this after sourcing the library.
# shellcheck disable=SC2034
FILONE_POSTGRES_CONTAINER=filone-platform-postgres-1

# Where a node kept its cluster while it ran the Alpine Postgres image. That
# cluster was initialised with en_US.utf8, which musl sorts in byte order and
# glibc sorts by language, so the Debian image opening it would read every text
# index out of order and miss rows without an error. Nor would Postgres notice:
# musl reports no collation version to compare. migrate-postgres-to-debian.sh
# moves the data into a new cluster in a directory of its own instead.
postgres_previous_data_dir() {
  printf '%s' "$FILONE_CONTROL_DIR/postgres"
}

# Written by migrate-postgres-to-debian.sh once the new cluster holds every
# database, with the directory it migrated into.
postgres_migrated_marker() {
  printf '%s' "$FILONE_STATE_DIR/postgres-migrated"
}

# The host directory the platform project mounts as Postgres's data directory,
# read from the resolved compose file.
postgres_data_dir() {
  compose_platform config --format json | python3 -c '
import json, sys

service = json.load(sys.stdin)["services"]["postgres"]
for volume in service.get("volumes") or []:
    if volume.get("target") == "/var/lib/postgresql/data":
        print(volume["source"])
        break
else:
    sys.exit("the postgres service mounts nothing at /var/lib/postgresql/data")
'
}

# The host directory the running Postgres container has as its data directory,
# read off the container rather than compose.yml, which may already name
# another.
postgres_container_data_dir() {
  docker inspect \
    -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' \
    "$FILONE_POSTGRES_CONTAINER"
}

# Refuse to start Postgres on a data directory that the node's cluster has not
# been migrated into. Without this, the merge that moves a node to the Debian
# image would start an empty cluster under Piri and Ingot on the next reconcile
# pass, and postgres-init would hand them empty databases.
#
# Passes on a node that never had a cluster in the old directory, since a new
# node initialises the configured one itself; on one whose checkout still mounts
# the old directory, because its image has not moved or the move was reverted;
# and on one migrate-postgres-to-debian.sh has finished.
require_postgres_migrated() {
  local configured previous marker
  configured="$(postgres_data_dir)" ||
    die "could not read Postgres's data directory from $FILONE_NODE_DIR/platform/compose.yml"
  previous="$(postgres_previous_data_dir)"
  marker="$(postgres_migrated_marker)"

  if [ "$configured" = "$previous" ]; then
    # A revert after a migration. With the old cluster gone, Postgres would
    # initialise an empty one in its place.
    [ ! -e "$marker" ] || [ -f "$previous/PG_VERSION" ] ||
      die "compose.yml mounts $previous again, but the cluster there was removed after
       the migration into $(cat "$marker"). Starting Postgres would hand Piri and
       Ingot empty databases. Undo the revert."
    return 0
  fi
  [ -f "$previous/PG_VERSION" ] || return 0
  [ "$(cat "$marker" 2>/dev/null)" = "$configured" ] && return 0

  die "compose.yml mounts $configured as Postgres's data directory, but this node's
       cluster is still in $previous. Starting Postgres there would hand Piri and
       Ingot empty databases. Run scripts/host/migrate-postgres-to-debian.sh, which
       moves the data across and finishes the deploy; docs/RUNBOOK.md has the
       procedure."
}

# Forget a migration once a revert has Postgres running on the old directory
# again. From then the old cluster takes the writes and the migrated copy falls
# behind, so a later merge has to wait for a new migration, which moves the
# stale copy aside, rather than start it. Not before: until the old cluster
# runs, the apps may still be on the migrated one, which holds the newest data.
# deploy-platform.sh calls this once the platform is healthy.
forget_reverted_postgres_migration() {
  local marker previous running
  marker="$(postgres_migrated_marker)"
  [ -e "$marker" ] || return 0
  previous="$(postgres_previous_data_dir)"
  [ "$(postgres_data_dir)" = "$previous" ] || return 0
  running="$(postgres_container_data_dir)" || return 0
  [ "$running" = "$previous" ] || return 0

  echo "  Postgres runs on $previous again; forgetting the migration into $(cat "$marker")"
  rm -f -- "$marker"
}

# Refuse to start the apps on a cluster a migration left half built. The
# migration stops them before it starts the new cluster, and starts them again
# once that cluster holds every database or the old one is back. A run killed
# in between leaves the new cluster running without the apps' data.
require_postgres_settled() {
  local running previous
  container_exists "$FILONE_POSTGRES_CONTAINER" || return 0
  running="$(postgres_container_data_dir)" || die "could not inspect $FILONE_POSTGRES_CONTAINER"
  previous="$(postgres_previous_data_dir)"

  [ "$running" != "$previous" ] || return 0
  [ -f "$previous/PG_VERSION" ] || return 0
  [ "$(cat "$(postgres_migrated_marker)" 2>/dev/null)" = "$running" ] && return 0

  die "$FILONE_POSTGRES_CONTAINER runs on $running, which migrate-postgres-to-debian.sh
       has not finished filling. Starting the apps would hand them a cluster without
       their data. Run migrate-postgres-to-debian.sh --rollback to start the old
       cluster and the apps, or run the migration again."
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
# With a service name, that service's definition is hashed together with the
# top-level networks, volumes, secrets and configs it references. Those live
# outside the service block, so a change to one of them would otherwise read as
# no change to any service. Without a service name, the whole project's
# definition is hashed.
compose_config_hash() {
  local compose_fn="$1" service="${2:-}"
  "$compose_fn" config --format json |
    FILONE_HASH_ROOT="$FILONE_NODE_DIR" python3 -c '
import hashlib, json, os, sys

document = json.load(sys.stdin)
root = os.path.realpath(os.environ["FILONE_HASH_ROOT"]) + os.sep

def referenced(service):
    keys = {
        "networks": list(service.get("networks") or {}),
        "volumes": [v["source"] for v in service.get("volumes") or []
                    if isinstance(v, dict) and v.get("type") == "volume"],
        "secrets": [s["source"] for s in service.get("secrets") or [] if isinstance(s, dict)],
        "configs": [c["source"] for c in service.get("configs") or [] if isinstance(c, dict)],
    }
    return {kind: {key: (document.get(kind) or {}).get(key) for key in names}
            for kind, names in keys.items() if names}

if len(sys.argv) > 1:
    name = sys.argv[1]
    services = {name: document["services"][name]}
    config = {"service": services[name], "referenced": referenced(services[name])}
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

# --- Piri ------------------------------------------------------------------

# The Piri services in the node's apps project, in index order: piri-0, piri-1
# and so on for a node that runs one Piri per storage volume, or the single
# `piri` of a node that has not moved to that layout. Every other name a Piri
# has on the box is derived from its service name: container filone-<service>,
# OpenBao path <service>, and secret files <service>.pem and
# <service>-owner-wallet.hex. Its Postgres database is the service name with
# `_` for `-` (piri_0), so a one-off query does not have to quote it.
#
# Read without interpolation, so it answers before apps.env has been rendered:
# keygen.sh needs the list on a node that has never deployed apps.
piri_services() {
  local services
  services="$(docker compose --project-directory "$FILONE_NODE_DIR/apps" -p filone-apps     config --no-interpolate --services)" ||
    die "could not read the services in nodes/$FILONE_NODE/apps/compose.yml"
  services="$(grep -E '^piri(-[0-9]+)?$' <<<"$services" | sort -V || true)"
  [ -n "$services" ] || die "nodes/$FILONE_NODE/apps/compose.yml defines no Piri service"
  printf '%s\n' "$services"
}

# The apps project's services other than Bucket Intelligence's two, one per
# line. deploy-rag.sh deploys and waits for those on its own, so a deploy that
# waits on these is never failed by them. Read without interpolation, as
# piri_services does.
apps_core_services() {
  local services
  services="$(docker compose --project-directory "$FILONE_NODE_DIR/apps" -p filone-apps \
    config --no-interpolate --services)" ||
    die "could not read the services in nodes/$FILONE_NODE/apps/compose.yml"
  grep -vxE 'rag-embed|rag-engine' <<<"$services" || true
}

# The URL a Piri service answers at and registers with sprue. A node that runs
# one Piri per storage volume names them piri-<n>.$PIRI_HOSTNAME_SUFFIX; a node
# with a single `piri` still has one PIRI_PUBLIC_URL.
piri_public_url() {
  local service="$1"
  if [ -n "${PIRI_HOSTNAME_SUFFIX:-}" ]; then
    printf 'https://%s.%s' "$service" "$PIRI_HOSTNAME_SUFFIX"
  else
    [ "$service" = piri ] ||
      die "nodes/$FILONE_NODE/node.env has no PIRI_HOSTNAME_SUFFIX to name $service by"
    [ -n "${PIRI_PUBLIC_URL:-}" ] || die "nodes/$FILONE_NODE/node.env has no PIRI_PUBLIC_URL"
    printf '%s' "$PIRI_PUBLIC_URL"
  fi
}

# The host directory a Piri service mounts at /data/piri, read from compose.yml
# because it differs per node: an EBS volume per Piri on dev, a directory on the
# shared data disk on staging.
piri_data_dir() {
  local service="$1" definition dir
  definition="$(docker compose --project-directory "$FILONE_NODE_DIR/apps" -p filone-apps \
    config --no-interpolate --format json)" ||
    die "could not read nodes/$FILONE_NODE/apps/compose.yml"
  dir="$(python3 -c '
import json, sys
service = json.load(sys.stdin)["services"][sys.argv[1]]
for volume in service.get("volumes") or []:
    if isinstance(volume, dict) and volume.get("target") == "/data/piri":
        print(volume["source"])
' "$service" <<<"$definition")" || die "could not read $service's volumes from compose.yml"
  [ -n "$dir" ] || die "$service in nodes/$FILONE_NODE/apps/compose.yml mounts nothing at /data/piri"
  printf '%s' "$dir"
}

# The Piri containers on this box, in index order. Read from Docker rather than
# from compose, for the reason given at container_exists below.
piri_containers() {
  local names
  names="$(docker ps -a --format '{{.Names}}')" || die "could not list containers"
  grep -E '^filone-piri(-[0-9]+)?$' <<<"$names" | sort -V || true
}

# --- Piri and Ingot ----------------------------------------------------------

# The containers a platform deploy has to take down before it touches anything
# underneath them, and bring back once it is done: Ingot and every Piri.
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
  local container stopped=1 piris
  piris="$(piri_containers)"
  # shellcheck disable=SC2086 # one container name per word
  for container in filone-ingot $piris; do
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
  local container piris
  piris="$(piri_containers)"
  # shellcheck disable=SC2086 # one container name per word
  for container in $piris filone-ingot; do
    if container_exists "$container"; then
      echo "  starting $container"
      docker start "$container" >/dev/null || die "could not start $container"
    fi
  done
}

# --- Health ----------------------------------------------------------------

# Wait until every container in a compose project is ready, or fail. Given
# service names, wait for those alone: a rolling restart waits for the service
# it just recreated, so one already unhealthy further down the line does not
# stop the rollout before it reaches it.
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
# Usage: wait_healthy <compose function name> [timeout seconds] [service...]
wait_healthy() {
  local compose_fn="$1" timeout="${2:-300}" deadline ready_streak=0
  shift "$(( $# < 2 ? $# : 2 ))"
  deadline=$(( $(date +%s) + timeout ))

  echo "==> waiting for health (timeout ${timeout}s)"
  while :; do
    local bad=0 pending=0 name status health restarts exitcode started_at started_epoch
    local ids inspected

    # Read both commands into variables before the loop. Feeding the loop from
    # a process substitution throws their exit status away, so a docker daemon
    # that went down after `up` would yield no rows, leave bad and pending at
    # zero, and be read as every service healthy.
    ids="$("$compose_fn" ps -aq "$@")" || die "could not list the project's containers"
    [ -n "$ids" ] || die "the project has no containers${*:+ for $*}"
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
      "$compose_fn" ps -a "$@"
      die "$bad service(s) crash-looping, dead or unhealthy"
    fi

    if [ "$pending" -eq 0 ]; then
      ready_streak=$((ready_streak + 1))
      [ "$ready_streak" -ge 2 ] && { echo "  all services healthy"; return 0; }
    else
      ready_streak=0
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      "$compose_fn" ps -a "$@"
      die "timed out waiting for health"
    fi
    sleep 5
  done
}

# --- Backups ---------------------------------------------------------------

FILONE_BACKUP_PATH=backup-target
FILONE_SNAPSHOT_SERVICE=filone-openbao-snapshot.service
FILONE_SNAPSHOT_TIMER=filone-openbao-snapshot.timer

# Read the backup target and the key that writes to it from
# filone/backup-target, where provision-backups.sh stored all five, into
# backup_bucket, backup_key_prefix, backup_aws_region, backup_access_key_id and
# backup_secret_access_key. Callers keep the secret in that variable and unset
# it once the upload is done.
load_backup_target() {
  bao_has "$FILONE_BACKUP_PATH" access_key_id ||
    die "OpenBao has no backup key at $FILONE_BAO_MOUNT/$FILONE_BACKUP_PATH; run
       scripts/host/provision-backups.sh"
  bao_has "$FILONE_BACKUP_PATH" bucket ||
    die "$FILONE_BAO_MOUNT/$FILONE_BACKUP_PATH holds the key pair but not the target it
       writes to, so it was stored before provision-backups.sh kept the target
       with it. Ask central to re-mint with MINT_ARGS=--reissue-backup-key, then
       run scripts/host/provision-backups.sh --replace."

  backup_bucket="$(bao_get "$FILONE_BACKUP_PATH" bucket)"
  backup_key_prefix="$(bao_get "$FILONE_BACKUP_PATH" key_prefix)"
  backup_aws_region="$(bao_get "$FILONE_BACKUP_PATH" aws_region)"
  backup_access_key_id="$(bao_get "$FILONE_BACKUP_PATH" access_key_id)"
  backup_secret_access_key="$(bao_get "$FILONE_BACKUP_PATH" secret_access_key)"

  [ "$backup_key_prefix" = "$REGION_LABEL/" ] ||
    die "the stored backup key writes under $backup_key_prefix, but this node is $REGION_LABEL
       and central's writer for it can write only under $REGION_LABEL/"
  # The key pair goes into a curl config line between double quotes, where a
  # quote or a backslash would change what curl reads. AWS keys contain neither.
  [[ "$backup_access_key_id" =~ ^[A-Z0-9]+$ ]] ||
    die "the stored access key ID is not in the form AWS issues"
  [[ "$backup_secret_access_key" =~ ^[A-Za-z0-9/+=]+$ ]] ||
    die "the stored secret access key is not in the form AWS issues"
}

# PUT one local file to s3://<backup_bucket>/<object_key> with the key
# load_backup_target read. Returns 0 on a 200. On any other answer it returns 1
# with the HTTP status in S3_PUT_STATUS and S3's error code and message in
# S3_PUT_ERROR, so each caller can say what the failure means for it. A request
# that never got an answer dies here: the backup jobs and the check share the
# route, and the fix is the same for all of them.
s3_put_file() {
  local file="$1" object_key="$2" content_type="$3"
  local url sha256 md5 curl_status=0 response
  url="https://$backup_bucket.s3.$backup_aws_region.amazonaws.com/$object_key"

  # S3 signs over the payload's SHA-256, and Object Lock refuses a put that
  # carries no Content-MD5 or other checksum. Hashed from the path, so a large
  # snapshot is read in chunks rather than held in memory.
  {
    read -r sha256
    read -r md5
  } < <(python3 - "$file" <<'PY'
import base64, hashlib, sys

sha, md = hashlib.sha256(), hashlib.md5()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        sha.update(chunk)
        md.update(chunk)
print(sha.hexdigest())
print(base64.b64encode(md.digest()).decode())
PY
  )
  [ -n "${sha256:-}" ] && [ -n "${md5:-}" ] || die "could not hash $file"

  # The key pair goes in on stdin as a curl config line. As a --user argument it
  # would sit in curl's argv, where anything on the host that can read /proc can
  # take it. printf is a shell builtin and never gets an argv of its own.
  response="$(printf 'user = "%s:%s"\n' "$backup_access_key_id" "$backup_secret_access_key" |
    curl -sS --max-time 300 --config - \
      --aws-sigv4 "aws:amz:$backup_aws_region:s3" \
      --upload-file "$file" \
      --header "Content-Type: $content_type" \
      --header "Content-MD5: $md5" \
      --header "x-amz-content-sha256: $sha256" \
      --write-out '\n%{http_code}' \
      "$url")" || curl_status=$?

  [ "$curl_status" -eq 0 ] ||
    die "could not reach $url (curl $curl_status). The backup jobs upload over the
       same route, so fix this node's HTTPS egress to S3 in $backup_aws_region."

  S3_PUT_STATUS="$(printf '%s' "$response" | tail -1)"
  # SC2034: read by the callers in check-backup-target.sh and snapshot-openbao.sh.
  # shellcheck disable=SC2034
  # Joined onto one line first: S3 puts Code and Message on one line, but an
  # S3-compatible target or a proxy may indent its XML across several.
  S3_PUT_ERROR="$(printf '%s' "$response" | sed '$d' | tr -d '\n' |
    sed -n 's|.*<Code>\(.*\)</Code>.*<Message>\(.*\)</Message>.*|\1: \2|p')"
  [ "$S3_PUT_STATUS" = 200 ]
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
# https://<every piri hostname>/.well-known/filone-node-status.json.
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
  local tmp revision_file project revision stamped_at service image_id repo_digest piris
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
  # stamps too, and platform is provisioned before apps exist. Each Piri is
  # listed under its own service name, so a Piri left on an old image shows up
  # as one mismatch rather than hiding behind the others.
  piris="$(piri_containers)"
  # shellcheck disable=SC2086 # one container name per word
  for service in ${piris//filone-/} ingot; do
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
