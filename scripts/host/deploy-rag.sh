#!/usr/bin/env bash
# Bring Bucket Intelligence (rag-embed, the embedding model, and rag-engine,
# which calls it) to what the checkout says, on a node whose apps compose.yml
# defines it. It touches those two containers and nothing else: it never starts,
# stops or recreates a Piri or Ingot, so a Piri stopped by hand stays stopped.
#
# deploy-apps.sh runs it last, after the Piris and Ingot are deployed and their
# hashes recorded. reconcile.sh runs it on its own while the retry marker is
# present and no commit has touched the apps project. Neither caller fails when
# this does: it logs a warning, exits non-zero and leaves the marker, and the
# next reconcile pass runs it again.
#
# Neither service is on the storage path, so nothing here waits for a proving
# window.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init
take_deploy_lock

# reconcile.sh reads this as a reason to run this script on its next pass.
rag_retry="$FILONE_STATE_DIR/rag-retry"

# Read without interpolation, as piri_services does, so a node without the
# engine never asks OpenBao for its secrets.
apps_services="$(docker compose --project-directory "$FILONE_NODE_DIR/apps" -p filone-apps \
  config --no-interpolate --services)" ||
  die "could not read the services in nodes/$FILONE_NODE/apps/compose.yml"
if ! grep -qx rag-engine <<<"$apps_services"; then
  rm -f "$rag_retry"
  exit 0
fi

echo "=== deploy Bucket Intelligence ($FILONE_NODE) ==="

# Written first and removed only once both services pass their health waits, so
# any failure on the way, a die included, leaves it for the next pass.
touch "$rag_retry"
warn_unless_deployed() {
  [ "$1" -eq 0 ] && return 0
  echo "WARNING: Bucket Intelligence (rag-embed, rag-engine) is not deployed and healthy." >&2
  echo "         Piri and Ingot are not affected; the next reconcile pass retries it." >&2
}
trap 'warn_unless_deployed $?' EXIT

bao_is_unsealed || die "OpenBao is sealed; run deploy-platform.sh first"

# compose_apps reads apps.env, which deploy-apps.sh renders into the tmpfs. A
# reboot empties it, and only an apps deploy renders it again.
[ -f "$FILONE_SECRETS_DIR/apps.env" ] ||
  die "$FILONE_SECRETS_DIR/apps.env is missing; run deploy-apps.sh"

# --- 1. Render --------------------------------------------------------------

echo "[1/3] Rendering the engine's secrets"
# The engine's bearer token and answer-model key, in an env file of their own
# rather than apps.env, so a change to them restarts the engine and nothing
# else. Each read lands in its own assignment, as in deploy-apps.sh, so a
# missing secret ends the run instead of rendering an empty one.
RAG_ENGINE_TOKEN="$(bao_get rag-engine engine_token)"
RAG_ANTHROPIC_API_KEY="$(bao_get rag-engine anthropic_api_key)"
export RAG_ENGINE_TOKEN RAG_ANTHROPIC_API_KEY
rag_engine_rendered=0
mark rag_engine_rendered render_template \
  "$FILONE_NODE_DIR/apps/templates/rag-engine.env.tpl" \
  "$FILONE_SECRETS_DIR/rag-engine.env"
unset RAG_ENGINE_TOKEN RAG_ANTHROPIC_API_KEY
# Rendering compares by content, so a run that dies after this would see no
# change on the next pass. Forgetting the recorded hash keeps the engine marked
# changed until a run records it healthy.
if [ "$rag_engine_rendered" -eq 1 ]; then
  rm -f "$FILONE_STATE_DIR/apps-rag-engine.sha256"
fi

# --- 2. Pull ----------------------------------------------------------------

echo "[2/3] Pulling images"
compose_apps pull --quiet rag-embed rag-engine

# --- 3. Deploy --------------------------------------------------------------

# Same change detection as Ingot: --no-recreate alone would never apply a new
# digest or a re-rendered env file to a running container. Each service's hash
# is recorded once it is healthy, so a broken engine does not recreate a healthy
# rag-embed on every retry.
echo "[3/3] rag-embed, then rag-engine"
rag_embed_changed=0
mark rag_embed_changed image_differs compose_apps rag-embed
rag_embed_config_hash="$(compose_config_hash compose_apps rag-embed)"
mark rag_embed_changed config_changed apps-rag-embed "$rag_embed_config_hash"
if [ "$rag_embed_changed" -eq 1 ]; then
  compose_apps up -d --force-recreate --no-deps rag-embed
else
  echo "  rag-embed: nothing changed"
  compose_apps up -d --no-recreate --no-deps rag-embed
fi
# An engine started before the embedding model is loaded fails its first sync,
# so the engine is neither started nor recreated until rag-embed is healthy.
wait_healthy compose_apps 300 rag-embed
config_hash_record apps-rag-embed "$rag_embed_config_hash"

rag_engine_changed=0
mark rag_engine_changed image_differs compose_apps rag-engine
rag_engine_config_hash="$(compose_config_hash compose_apps rag-engine)"
mark rag_engine_changed config_changed apps-rag-engine "$rag_engine_config_hash"
if [ "$rag_engine_changed" -eq 1 ]; then
  compose_apps up -d --force-recreate --no-deps rag-engine
else
  echo "  rag-engine: nothing changed"
  compose_apps up -d --no-recreate --no-deps rag-engine
fi
wait_healthy compose_apps 180 rag-engine
config_hash_record apps-rag-engine "$rag_engine_config_hash"

rm -f "$rag_retry"
echo "=== Bucket Intelligence deploy complete ==="
