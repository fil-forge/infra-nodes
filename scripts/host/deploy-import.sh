#!/usr/bin/env bash
# Bring the import service to what the checkout says, on a node whose apps
# compose.yml defines it. It touches that one container and nothing else: it
# never starts, stops or recreates a Piri, Ingot or Bucket Intelligence.
#
# deploy-apps.sh runs it last, after the Piris and Ingot are deployed and their
# hashes recorded. reconcile.sh runs it on its own while the retry marker is
# present and no commit has touched the apps project. Neither caller fails when
# this does: it logs a warning, exits non-zero and leaves the marker, and the
# next reconcile pass runs it again.
#
# Until every setting import_service_placeholders checks is filled in, it says
# which are left, removes a container an earlier deploy left running, and exits
# 0 without starting anything and without a marker:
# there is nothing to retry until a commit fills them, and that commit deploys
# the apps, which runs this.
#
# In order: the firewall table from the host's client list, so the published
# port is never open without it; the service's address on the filone network;
# its secrets from OpenBao; its image, pulled with a registry login that lives
# only in the secrets tmpfs for the length of the pull; then the container,
# recreated only when something it reads changed.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

filone_init
take_deploy_lock

SERVICE=import-service
CONTAINER=filone-import-service
# The image's user, which compose.yml runs it as. Its files on the tmpfs are
# owned by it, since it cannot read root's.
SERVICE_UID=10001
SERVICE_SECRETS="$FILONE_SECRETS_DIR/import-service"
# The OpenBao path, under the node's mount, that holds every secret below.
BAO_PATH=import-service

# reconcile.sh reads this as a reason to run this script on its next pass.
import_retry="$FILONE_STATE_DIR/import-retry"

# Read without interpolation, as piri_services does, so a node without the
# service never asks OpenBao for its secrets.
apps_services="$(docker compose --project-directory "$FILONE_NODE_DIR/apps" -p filone-apps \
  config --no-interpolate --services)" ||
  die "could not read the services in nodes/$FILONE_NODE/apps/compose.yml"
if ! grep -qx "$SERVICE" <<<"$apps_services"; then
  rm -f "$import_retry"
  exit 0
fi

echo "=== deploy the import service ($FILONE_NODE) ==="

unset_settings="$(import_service_placeholders)"
if [ -n "$unset_settings" ]; then
  echo "  not configured, so not started. Still a placeholder:"
  while read -r name; do echo "    $name"; done <<<"$unset_settings"
  echo "  docs/runbook/set-up-import-service.md says where each comes from."
  import_service_remove "$CONTAINER"
  rm -f "$import_retry"
  exit 0
fi

# Written first and removed only once the service passes its health wait, so
# any failure on the way, a die included, leaves it for the next pass.
touch "$import_retry"
docker_config=""
finish() {
  local status="$1"
  [ -z "$docker_config" ] || rm -rf "$docker_config"
  [ "$status" -eq 0 ] && return 0
  echo "WARNING: the import service is not deployed and healthy." >&2
  echo "         Piri and Ingot are not affected; the next reconcile pass retries it." >&2
}
trap 'finish $?' EXIT

bao_is_unsealed || die "OpenBao is sealed; run deploy-platform.sh first"

# compose_apps reads apps.env, which deploy-apps.sh renders into the tmpfs. A
# reboot empties it, and the first reconcile pass after boot runs the apps
# deploy that renders it again.
[ -f "$FILONE_SECRETS_DIR/apps.env" ] ||
  die "$FILONE_SECRETS_DIR/apps.env is missing; run deploy-apps.sh"

IMPORT_SERVICE_IMAGE="$(import_service_image)"
[[ "$IMPORT_SERVICE_IMAGE" =~ ^[^@[:space:]]+:[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] ||
  die "IMPORT_SERVICE_IMAGE in nodes/$FILONE_NODE/apps/versions.env is not pinned as
       <image>:<tag>@sha256:<digest>."
[[ "$IMPORT_SERVICE_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$IMPORT_SERVICE_PORT" -le 65535 ] ||
  die "IMPORT_SERVICE_PORT in nodes/$FILONE_NODE/node.env is '$IMPORT_SERVICE_PORT', not a port."
[[ "$IMPORT_SERVICE_RECOVERY_PUBLIC_KEY" =~ ^[0-9a-fA-F]+$ ]] ||
  die "IMPORT_SERVICE_RECOVERY_PUBLIC_KEY in nodes/$FILONE_NODE/node.env is not hex."

# --- 1. Firewall ------------------------------------------------------------

echo "[1/5] Firewall"
"$SCRIPT_DIR/import-firewall.sh"

# --- 2. Address -------------------------------------------------------------

# The service refuses the wildcard address, and its healthcheck dials the same
# address, so the container gets a fixed one, import_service_address's.
# Derived here rather than committed. A container that already holds it stops
# the deploy rather than sharing it.
echo "[2/5] Address on the filone network"
subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' filone)" ||
  die "could not read the subnet of the filone network"
IMPORT_SERVICE_CONTAINER_ADDRESS="$(import_service_address "$subnet")" ||
  die "could not derive the service's address from the filone network's $subnet"
holders="$(docker network inspect \
  -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' filone)" ||
  die "could not list the containers on the filone network"
holder="$(awk -v address="$IMPORT_SERVICE_CONTAINER_ADDRESS" -v self="$CONTAINER" \
  '{ split($2, a, "/") } a[1] == address && $1 != self { print $1 }' <<<"$holders")"
[ -z "$holder" ] ||
  die "$holder holds $IMPORT_SERVICE_CONTAINER_ADDRESS on the filone network, the address the
       import service listens on. Recreate $holder so Docker gives it another."
export IMPORT_SERVICE_CONTAINER_ADDRESS
echo "  $IMPORT_SERVICE_CONTAINER_ADDRESS"

# --- 3. Render --------------------------------------------------------------

echo "[3/5] Rendering the service's secrets"

# A value written into the single-quoted env file or the password file: one
# line, no quote. Named in the message, never printed.
plain_value() { # plain_value <field> <value>
  case "$2" in
    *"'"* | *$'\n'* | *$'\r'*)
      die "OpenBao's $FILONE_BAO_MOUNT/$BAO_PATH#$1 holds a quote or a line break, which the
       service's env file cannot carry. Store it again without one." ;;
  esac
}

install -d -m 0500 -o "$SERVICE_UID" -g "$SERVICE_UID" "$SERVICE_SECRETS"

# Each read in its own assignment before it is used, as in deploy-apps.sh, so a
# missing secret ends the run instead of rendering an empty one. The PEMs get
# back the trailing newline OpenBao drops. Each changed file forgets the
# recorded hash at once, so a run that dies part way through still leaves the
# service marked changed for the next pass.
rendered=0
hash_name="apps-$SERVICE"
render() { mark rendered forget_hash_on_change "$hash_name" "$@"; }
tls_cert="$(bao_get "$BAO_PATH" tls_cert)"
render write_secret_file "$SERVICE_SECRETS/server.pem" "$tls_cert
"
tls_key="$(bao_get "$BAO_PATH" tls_key)"
render write_secret_file "$SERVICE_SECRETS/server-key.pem" "$tls_key
"
client_ca="$(bao_get "$BAO_PATH" client_ca)"
render write_secret_file "$SERVICE_SECRETS/client-ca.pem" "$client_ca
"
unset tls_cert tls_key client_ca

# libpq's password file, matching any host, port, database and user, since the
# DSN names them.
ledger_password="$(bao_get "$BAO_PATH" ledger_password)"
plain_value ledger_password "$ledger_password"
pgpass="$(import_pgpass_line "$ledger_password")"
render write_secret_file "$SERVICE_SECRETS/pgpass" "$pgpass
"
unset ledger_password pgpass

s3_secret_key="$(bao_get "$BAO_PATH" s3_secret_key)"
render write_secret_file "$SERVICE_SECRETS/s3-secret-key" "$s3_secret_key"
unset s3_secret_key

# The site secret every pack's keys derive from. OpenBao holds it base64; the
# file holds the bytes, which import_site_secret_file checks as the service
# would before writing them.
site_secret="$(bao_get "$BAO_PATH" site_secret)"
render import_site_secret_file "$FILONE_BAO_MOUNT/$BAO_PATH#site_secret" \
  "$SERVICE_SECRETS/site-secret" "$site_secret"
unset site_secret

# The service reads its files as its own user; compose reads the env file as
# root.
chown "$SERVICE_UID:$SERVICE_UID" "$SERVICE_SECRETS"/* ||
  die "could not give $SERVICE_SECRETS to the service's user"

IMPORT_SERVICE_LEDGER_DSN="$(bao_get "$BAO_PATH" ledger_dsn)"
IMPORT_SERVICE_S3_ACCESS_KEY_ID="$(bao_get "$BAO_PATH" s3_access_key_id)"
plain_value ledger_dsn "$IMPORT_SERVICE_LEDGER_DSN"
plain_value s3_access_key_id "$IMPORT_SERVICE_S3_ACCESS_KEY_ID"
# The password lives in the password file; libpq would use one in the DSN
# first, and the DSN is the less guarded of the two.
if ledger_dsn_has_password "$IMPORT_SERVICE_LEDGER_DSN"; then
  die "OpenBao's $FILONE_BAO_MOUNT/$BAO_PATH#ledger_dsn carries a password. Store the DSN
       without it; the password goes in #ledger_password."
fi
export IMPORT_SERVICE_LEDGER_DSN IMPORT_SERVICE_S3_ACCESS_KEY_ID
render render_template \
  "$FILONE_NODE_DIR/apps/templates/import-service.env.tpl" \
  "$FILONE_SECRETS_DIR/import-service.env"
unset IMPORT_SERVICE_LEDGER_DSN IMPORT_SERVICE_S3_ACCESS_KEY_ID

# --- 4. Pull ----------------------------------------------------------------

# Only when the host lacks the pinned image, as deploy-apps.sh pulls. The image
# is private: the login goes into a Docker config directory on the secrets
# tmpfs, used for this one pull and removed with it, so no registry credential
# is left on the disk.
echo "[4/5] Image"
if docker image inspect "$IMPORT_SERVICE_IMAGE" >/dev/null 2>&1; then
  echo "  present"
else
  registry="${IMPORT_SERVICE_IMAGE%%/*}"
  registry_username="$(bao_get "$BAO_PATH" registry_username)"
  registry_token="$(bao_get "$BAO_PATH" registry_token)"
  docker_config="$(mktemp -d "$FILONE_SECRETS_DIR/.docker.XXXXXX")" ||
    die "mktemp failed in $FILONE_SECRETS_DIR"
  DOCKER_CONFIG="$docker_config" docker login "$registry" \
    --username "$registry_username" --password-stdin <<<"$registry_token" >/dev/null ||
    die "could not log in to $registry with $FILONE_BAO_MOUNT/$BAO_PATH#registry_username"
  unset registry_token
  DOCKER_CONFIG="$docker_config" docker pull --quiet "$IMPORT_SERVICE_IMAGE" >/dev/null ||
    die "could not pull $IMPORT_SERVICE_IMAGE"
  rm -rf "$docker_config"
  docker_config=""
  echo "  pulled"
fi

# --- 5. Deploy --------------------------------------------------------------

# Same change detection as deploy-rag.sh's: --no-recreate alone would never
# apply a new digest or a re-rendered file to a running container.
echo "[5/5] The service"

# As deploy-rag.sh's: start a service whose image and definition match what
# was recorded, and recreate one that went unhealthy after it was.
start_unchanged() {
  local id state=""
  id="$(compose_apps ps -aq "$SERVICE")" || die "could not list $SERVICE's container"
  if [ -n "$id" ]; then
    state="$(docker inspect --type container \
      -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")" ||
      die "could not inspect $SERVICE's container"
  fi
  if [[ "$state" == *" unhealthy" ]]; then
    echo "  nothing changed, but it is ${state% unhealthy} and unhealthy; recreating it"
    compose_apps up -d --force-recreate --no-deps "$SERVICE"
  else
    echo "  nothing changed"
    compose_apps up -d --no-recreate --no-deps "$SERVICE"
  fi
}

changed="$rendered"
mark changed image_differs compose_apps "$SERVICE"
config_hash="$(compose_config_hash compose_apps "$SERVICE")"
mark changed config_changed "$hash_name" "$config_hash"
if [ "$changed" -eq 1 ]; then
  compose_apps up -d --force-recreate --no-deps "$SERVICE"
else
  start_unchanged
fi
wait_healthy compose_apps 180 "$SERVICE"
config_hash_record "$hash_name" "$config_hash"

rm -f "$import_retry"
echo "=== import service deploy complete ==="
