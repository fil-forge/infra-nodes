#!/usr/bin/env bash
# Bring the platform project to what the checkout says it should be.
#
# Runs on the node, as root, from the reconcile timer or by hand. Idempotent: a
# run that changes nothing pulls, finds every rendered file identical and every
# container already correct, stamps success and leaves Piri and Ingot alone.
#
# A run that does have something to apply goes through Piri's proving gate first
# and stops both apps while it works. Postgres and Caddy are underneath them, so
# recreating either one under a running Piri is the same missed proof an apps
# deploy is careful to avoid.
#
# It does not initialise OpenBao and does not create any secret. Everything it
# renders has to be in OpenBao already, which is provision-platform.sh's job.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

filone_init

# Reconcile resets the checkout under whatever is running, so a hand-started
# deploy waits for it rather than reading half of one revision and half of the
# next. A deploy reconcile started itself already holds this.
take_deploy_lock

echo "=== deploy platform ($FILONE_NODE) ==="

if node_ships_telemetry; then
  require_configured GRAFANA_LOGS_USER 000000
  require_configured GRAFANA_METRICS_USER 000000
  require_configured GRAFANA_TRACES_USER 000000
fi

echo "[1/7] Reading secrets"
write_openbao_env

# Start OpenBao first and on its own. Everything below reads from it, and a
# naive `up -d` would start Postgres with an unrendered password.
#
# --no-recreate: this only has to make sure OpenBao is running. A new image, a
# rotated seal token or an edited bao.hcl is applied further down, inside the
# gate, like every other platform change. Without the flag a new image would
# recreate the root of trust here, under a running Ingot, and then once more in
# the gated pass because the recorded hash still differs.
compose_platform up -d --no-recreate openbao

if ! bao_is_unsealed; then
  # Give the transit handshake a moment on a cold start before calling it.
  sleep 10
fi
bao_is_unsealed || die "OpenBao is sealed. Either the seal token is revoked or expired, or the transit key
       named in platform/config/openbao/bao.hcl does not exist on the central
       OpenBao yet. 'docker logs filone-openbao' says which."

# Also renewed on every reconcile pass, so this one is for the operator running
# this script by hand on a node that has been quiet.
renew_bao_token
renew_ingot_regionkey_token

POSTGRES_ADMIN_PASSWORD="$(bao_get postgres admin_password)"
PIRI_POSTGRES_PASSWORD="$(bao_get postgres piri_password)"
INGOT_POSTGRES_PASSWORD="$(bao_get postgres ingot_password)"
export POSTGRES_ADMIN_PASSWORD PIRI_POSTGRES_PASSWORD INGOT_POSTGRES_PASSWORD

# Only where Alloy runs in this project. A node whose host ships its telemetry
# has no such secret and no template asking for one.
if node_ships_telemetry; then
  GRAFANA_PUSH_TOKEN="$(bao_get external grafana_push_token)"
  export GRAFANA_PUSH_TOKEN
fi

echo "[2/7] Rendering secrets"
# Its changed/unchanged answer is not needed here. Everything in platform.env
# reaches a container through that service's environment, so a re-rendered
# value shows up in the per-service hashes below.
render_template \
  "$FILONE_NODE_DIR/platform/templates/platform.env.tpl" \
  "$FILONE_SECRETS_DIR/platform.env" || true

echo "[3/7] Pulling images"
# Before the gate, not after. Pulling can take minutes, and doing it inside the
# safe window would spend the window on a download.
compose_platform pull --quiet

echo "[4/7] Deciding what changed"
# Per service, as deploy-apps.sh does, so that an edit to the Caddyfile
# recreates Caddy and leaves OpenBao and Postgres running. One hash for the
# whole project would have to recreate the whole project to be sure the edit
# applied.
changed_services=()
declare -A platform_service_hash=()
for service in $(compose_platform config --services); do
  service_changed=0
  mark service_changed image_differs compose_platform "$service"
  platform_service_hash[$service]="$(compose_config_hash compose_platform "$service")"
  mark service_changed config_changed "platform-$service" "${platform_service_hash[$service]}"
  if [ "$service_changed" -eq 1 ]; then changed_services+=("$service"); fi
done

if [ "${#changed_services[@]}" -gt 0 ]; then
  echo "  changed: ${changed_services[*]}"
else
  echo "  nothing changed"
fi

# --- Applying ----------------------------------------------------------------

# Anything below that exits non-zero leaves Piri and Ingot down, so bring them
# back rather than waiting for the next reconcile pass to notice. Cleared before
# the restart so a failure inside the handler cannot loop.
apps_stopped=0
restore_apps() {
  local status=$?
  if [ "$status" -eq 0 ] || [ "$apps_stopped" -eq 0 ]; then
    return 0
  fi
  apps_stopped=0
  echo "platform deploy failed; bringing Piri and Ingot back up" >&2
  start_apps || true
}
trap restore_apps EXIT

echo "[5/7] Applying"
if [ "${#changed_services[@]}" -gt 0 ]; then
  echo "  waiting for a safe restart window"
  "$SCRIPT_DIR/pdp-gate.sh"
  if stop_apps; then apps_stopped=1; fi
  # --force-recreate because most of what changes here is the *content* of a
  # bind-mounted file: the Caddyfile, the Alloy config, bao.hcl. Compose decides
  # recreation from the service definition, which those leave untouched, so a
  # plain `up -d` would report success and leave the old process serving the
  # old file. Only the listed services are forced; a dependency such as
  # Postgres under postgres-init is recreated only if its own definition
  # differs. OpenBao is in the list like any other service: the early start
  # above never recreates it, so this is where its changes land. Never run
  # this without service names: that recreates everything.
  compose_platform up -d --force-recreate "${changed_services[@]}"
fi
# Create a service added to compose.yml and remove one deleted from it, without
# recreating anything else: whether a service restarts was decided, and gated,
# further up. --no-recreate is the guarantee that goes with skipping the gate:
# having decided nothing changed, this must not recreate Postgres out from under
# a Piri that is mid-proof on the strength of something the checks above missed.
# Removing a deleted service is not gated. The only platform service one would
# delete under running apps is Alloy, which they do not depend on.
compose_platform up -d --no-recreate --remove-orphans

echo "[6/7] Health"
wait_healthy compose_platform 300

echo "[7/7] Piri and Ingot"
if [ "$apps_stopped" -eq 1 ]; then
  start_apps
  apps_stopped=0
  # What they should be running is deploy-apps.sh's business. This only has to
  # know that the two it took down came back on the platform it rebuilt.
  wait_healthy compose_apps 420
else
  echo "  left running"
fi

trap - EXIT

# Only now, with the apps back up. Recording the hashes any earlier would make a
# run that left them down look like an up-to-date one on the next pass, and the
# next pass would then skip the gate, skip the restart and print "left running"
# over two stopped containers.
for service in "${!platform_service_hash[@]}"; do
  config_hash_record "platform-$service" "${platform_service_hash[$service]}"
done
# The project-wide record the per-service ones replaced.
rm -f "$FILONE_STATE_DIR/platform.sha256"

stamp_deploy_success platform
echo "=== platform deploy complete ==="
