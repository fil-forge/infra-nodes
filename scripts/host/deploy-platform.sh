#!/usr/bin/env bash
# Bring the platform project to what the checkout says it should be.
#
# Runs on the node, as root, from the reconcile timer or by hand. Idempotent: a
# run that changes nothing pulls, finds every rendered file identical and every
# container already correct, and stamps success.
#
# It does not initialise OpenBao and does not create any secret. Everything it
# renders has to be in OpenBao already, which is provision-platform.sh's job.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init

echo "=== deploy platform ($FILONE_NODE) ==="

echo "[1/5] Reading secrets"
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

echo "[2/5] Rendering secrets"
changed=0
render_template \
  "$FILONE_NODE_DIR/platform/templates/platform.env.tpl" \
  "$FILONE_SECRETS_DIR/platform.env" && changed=1
[ "$changed" -eq 1 ] && echo "  platform.env changed" || echo "  platform.env unchanged"

echo "[3/5] Pulling images"
compose_platform pull --quiet

echo "[4/5] Applying"
# --remove-orphans so a service deleted from compose.yml actually goes away.
# Compose recreates a container when its image, its environment or its mounts
# differ from what is running and leaves the rest alone, so an unchanged deploy
# does not restart anything.
compose_platform up -d --remove-orphans

echo "[5/5] Health"
wait_healthy compose_platform 300

stamp_deploy_success platform
echo "=== platform deploy complete ==="
