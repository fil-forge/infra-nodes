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

require_configured GRAFANA_LOGS_USER 000000
require_configured GRAFANA_METRICS_USER 000000

echo "[1/7] Reading secrets"
write_openbao_env

# Start OpenBao first and on its own. Everything below reads from it, and a
# naive `up -d` would start Postgres with an unrendered password.
compose_platform up -d openbao

if ! bao_is_unsealed; then
  # Give the transit handshake a moment on a cold start before calling it.
  sleep 10
fi
bao_is_unsealed || die "OpenBao is sealed. Either the seal token is revoked or expired, or the transit key
       named in platform/config/openbao/bao.hcl does not exist on the central
       OpenBao yet. 'docker logs filone-openbao' says which."

# `bao token renew` with no argument renews the token the client is using. A
# periodic token stops renewing itself when nothing renews it, and this runs
# every five minutes from the reconcile timer, which is far inside any period
# worth setting. The failure is loud on purpose: a deploy token nobody renews
# expires, and every deploy after that stops at the first secret read.
bao token renew >/dev/null ||
  die "could not renew the local OpenBao deploy token"

POSTGRES_ADMIN_PASSWORD="$(bao_get postgres admin_password)"
PIRI_POSTGRES_PASSWORD="$(bao_get postgres piri_password)"
INGOT_POSTGRES_PASSWORD="$(bao_get postgres ingot_password)"
GRAFANA_PUSH_TOKEN="$(bao_get external grafana_push_token)"
export POSTGRES_ADMIN_PASSWORD PIRI_POSTGRES_PASSWORD INGOT_POSTGRES_PASSWORD
export GRAFANA_PUSH_TOKEN

platform_changed=0

echo "[2/7] Rendering secrets"
mark platform_changed render_template \
  "$FILONE_NODE_DIR/platform/templates/platform.env.tpl" \
  "$FILONE_SECRETS_DIR/platform.env"

echo "[3/7] Pulling images"
# Before the gate, not after. Pulling can take minutes, and doing it inside the
# safe window would spend the window on a download.
compose_platform pull --quiet

echo "[4/7] Deciding what changed"
for service in $(compose_platform config --services); do
  mark platform_changed image_differs compose_platform "$service"
done
platform_config_hash="$(compose_config_hash compose_platform)"
mark platform_changed config_changed platform "$platform_config_hash"

if [ "$platform_changed" -eq 1 ]; then
  echo "  something changed"
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
if [ "$platform_changed" -eq 1 ]; then
  echo "  waiting for a safe restart window"
  "$SCRIPT_DIR/pdp-gate.sh"
  if stop_apps; then apps_stopped=1; fi
  # --remove-orphans so a service deleted from compose.yml actually goes away.
  # Compose recreates a container when its image, its environment or its mounts
  # differ from what is running and leaves the rest alone.
  compose_platform up -d --remove-orphans
else
  # --no-recreate is the guarantee that goes with skipping the gate: having
  # decided nothing changed, this must not recreate Postgres out from under a
  # Piri that is mid-proof on the strength of something the checks above missed.
  compose_platform up -d --no-recreate --remove-orphans
fi

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

# Only now, with the apps back up. Recording the hash any earlier would make a
# run that left them down look like an up-to-date one on the next pass, and the
# next pass would then skip the gate, skip the restart and print "left running"
# over two stopped containers.
config_hash_record platform "$platform_config_hash"

stamp_deploy_success platform
echo "=== platform deploy complete ==="
