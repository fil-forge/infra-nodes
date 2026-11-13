#!/usr/bin/env bash
# Make the node match the ref it tracks, and deploy only what changed.
#
# Runs every five minutes from filone-reconcile.timer. This is how a change
# reaches a node: merge it, and within five minutes the node is running it.
#
# Deliberately narrow. It updates the checkout, works out which of the two
# compose projects the new commits touch, and calls the ordinary deploy scripts.
# It creates nothing and prompts for nothing. The one secret it touches is the
# node's own host token, which it renews and never prints.
#
# It also deploys the apps when none has succeeded since boot. A reboot empties
# the tmpfs that holds their keys and rendered configs, and no Piri or Ingot can
# start without them.
#
# The ref it tracks is FILONE_GIT_REF in /etc/fil-one/node.conf, which is the
# only statement of it. Point a node at a feature branch by editing that file.
set -euo pipefail

# Reconcile replaces the very files it is executing from. Bash reads a script
# incrementally, so a `git reset --hard` partway through this one can leave the
# shell reading from a different file at a different offset. Re-exec from a copy
# before touching the checkout.
#
# Through the interpreter, not by executing the copy. /run is mounted noexec on
# some hosts, and a script bash opens and reads needs neither an exec-capable
# mount nor an exec bit.
if [ -z "${FILONE_RECONCILE_COPY:-}" ]; then
  copy_dir="$(mktemp -d /run/fil-one-reconcile.XXXXXX)"
  cp -a "$(dirname "$(readlink -f "$0")")/." "$copy_dir/"
  FILONE_RECONCILE_COPY="$copy_dir" exec "$BASH" "$copy_dir/reconcile.sh" "$@"
fi
trap 'rm -rf "$FILONE_RECONCILE_COPY"' EXIT

# shellcheck source=lib.sh
. "$FILONE_RECONCILE_COPY/lib.sh"

filone_init

REF="${FILONE_GIT_REF:-main}"

echo "=== reconcile ($FILONE_NODE) ==="

# Before the checkout is touched and until this script exits, so a manual
# deploy started from a shell reads one revision from end to end. The deploy
# scripts below take the same lock when they are run on their own.
take_deploy_lock

# --- 1. Update the checkout -------------------------------------------------

# Refuse to clobber hand edits. The reset below would discard uncommitted
# changes to tracked files without saying so, and a node someone is debugging on
# is exactly where that hurts. Untracked files are left alone on purpose.
if ! git -C "$FILONE_CHECKOUT" diff --quiet ||
  ! git -C "$FILONE_CHECKOUT" diff --cached --quiet; then
  git -C "$FILONE_CHECKOUT" status --short --untracked-files=no >&2
  die "$FILONE_CHECKOUT has uncommitted changes to tracked files; not reconciling"
fi

before="$(git -C "$FILONE_CHECKOUT" rev-parse HEAD)"
git -C "$FILONE_CHECKOUT" fetch --quiet --tags --force origin
# origin/<ref> for a branch. A tag or a commit sha has no origin/ prefix, and
# the fetch above brought both local, so fall back to the bare ref.
git -C "$FILONE_CHECKOUT" reset --quiet --hard "origin/$REF" 2>/dev/null ||
  git -C "$FILONE_CHECKOUT" reset --quiet --hard "$REF"
after="$(git -C "$FILONE_CHECKOUT" rev-parse HEAD)"

if [ "$before" = "$after" ]; then
  echo "  already at ${after:0:8}"
else
  echo "  ${before:0:8} -> ${after:0:8}"
fi

# --- 2. Reconcile the systemd units -----------------------------------------

sync_systemd_units

# The staging appliance uses the host's Caddy. Its snippet is imported directly
# from this checkout, so a changed snippet takes effect only after the combined
# host configuration validates and caddy-guppy reloads.
if [ "${FILONE_HOST_CADDY:-false}" = true ] && [ "$before" != "$after" ] &&
  git -C "$FILONE_CHECKOUT" diff --name-only "$before" "$after" |
    grep -qx "nodes/$FILONE_NODE/platform/config/caddy/host-caddy.caddy"; then
  "$FILONE_CHECKOUT/scripts/host/reload-staging-host-caddy.sh"
fi

# --- 3. Work out what changed ----------------------------------------------

# Create what the compose files bind from a mounted volume, and order Docker
# after those mounts. Each pass, so a node that predates either gets them
# without a manual step.
create_bind_sources
sync_docker_mount_order

# And stop anything running on a volume that is not mounted, such as a container
# Docker restarted at boot on a directory an earlier pass left behind. Before
# the check below, which ends the pass when the control volume is the one
# missing.
stop_unusable_services platform
stop_unusable_services apps

# The revisions compared below, and every deploy, live on the control volume.
# Without it there is nothing to compare against and nothing safe to deploy. The
# token renewals further down go through the local OpenBao, which is on the
# same volume, so stopping here loses none of them. The pass is not stamped, so
# the reconcile deadman alert fires.
require_control_volume

# Per project, against the revision that project was last deployed from rather
# than against the checkout's previous HEAD. A deploy that failed leaves its
# revision unrecorded, so the next pass sees the same work still to do; diffing
# HEAD to HEAD would report nothing and stamp the pass a success.
deployed_rev() {
  local project="$1" rev
  rev="$(cat "$FILONE_REVISIONS_DIR/$project" 2>/dev/null || true)"
  [ -n "$rev" ] || return 0

  # Report none for a recorded revision this repository no longer has, after a
  # force-push or a gc. That deploys the project, which is the safe way to be
  # wrong; diffing against a missing object fails the pass instead.
  git -C "$FILONE_CHECKOUT" cat-file -e "$rev^{commit}" 2>/dev/null || return 0
  printf '%s' "$rev"
}

# The shared helpers and the node's own non-secret configuration feed both
# projects, so a change to either deploys both.
shared_paths="^scripts/host/|^nodes/$FILONE_NODE/node\.env$"

project_is_stale() {
  local project="$1" pattern="$2" base
  base="$(deployed_rev "$project")"

  if [ -z "$base" ]; then
    echo "  $project has no deployed revision to compare against"
    return 0
  fi
  [ "$base" != "$after" ] || return 1

  git -C "$FILONE_CHECKOUT" diff --name-only "$base" "$after" | grep -qE "$pattern" || return 1
  echo "  $project changed since ${base:0:8}"
}

deploy_platform=0
deploy_apps=0
if project_is_stale platform "$shared_paths|^nodes/$FILONE_NODE/platform/"; then deploy_platform=1; fi
if project_is_stale apps "$shared_paths|^nodes/$FILONE_NODE/apps/"; then deploy_apps=1; fi
# A reboot empties the tmpfs that holds the rendered secrets, and Docker cannot
# start a Piri or Ingot without them. No commit changed, so the staleness check
# above sees nothing to do. The marker lives on the same tmpfs and is written
# only by an apps deploy that finished healthy.
if [ "$deploy_apps" -eq 0 ] && [ ! -e "$FILONE_APPS_DEPLOYED_MARKER" ]; then
  echo "  no apps deploy has succeeded since boot"
  deploy_apps=1
fi
# Left by a Bucket Intelligence deploy that did not finish healthy, so the
# engine is retried without waiting for a commit. With no apps commit to deploy,
# the retry is deploy-rag.sh alone, which never starts, stops or recreates a
# Piri or Ingot. A full apps deploy runs deploy-rag.sh itself.
retry_rag=0
if [ "$deploy_apps" -eq 0 ] && [ -e "$FILONE_STATE_DIR/rag-retry" ]; then
  echo "  Bucket Intelligence has a deploy to retry"
  retry_rag=1
fi

# --- 4. Renew the local OpenBao token ---------------------------------------

# Every pass, including a pass that deploys nothing. deploy-platform.sh renews
# it too, but a node can go days without a platform commit, and the token's
# period is shorter than that.
renew_bao_token

# After the host token, so a node that has no region token yet still keeps its
# host token alive. Every five minutes against a 72h period, which leaves
# plenty of room: a reconcile stalled for three days is already alarmed through
# deploy_last_success_timestamp.
renew_ingot_regionkey_token

# --- 5. Deploy --------------------------------------------------------------

# From the checkout, not from the copy this script re-exec'd out of. A commit
# that fixes a deploy script has to take effect on the pass that pulls it: the
# checkout HEAD has already moved, so a later pass sees nothing to do.
if [ "$deploy_platform" -eq 1 ]; then
  echo "==> deploying platform"
  "$FILONE_CHECKOUT/scripts/host/deploy-platform.sh"
fi

if [ "$deploy_apps" -eq 1 ]; then
  echo "==> deploying apps"
  "$FILONE_CHECKOUT/scripts/host/deploy-apps.sh"
elif [ "$retry_rag" -eq 1 ]; then
  echo "==> retrying Bucket Intelligence"
  # A failure is logged as a warning and leaves the marker for the next pass.
  # It does not fail this one: Piri and Ingot are not involved.
  "$FILONE_CHECKOUT/scripts/host/deploy-rag.sh" || true
fi

if [ "$deploy_platform" -eq 0 ] && [ "$deploy_apps" -eq 0 ] && [ "$retry_rag" -eq 0 ]; then
  echo "  nothing to deploy"
fi

# Stamped on every pass that gets this far, including a pass that deployed
# nothing. That is what makes it a deadman: the metric goes stale when the node
# stops reconciling, whether or not anyone was shipping.
stamp_deploy_success reconcile

# Every pass, so a write whose snapshot failed, or one made by a script that
# does not ask for a snapshot itself, goes up within five minutes rather than
# at the next daily run.
request_openbao_snapshot
echo "=== reconcile complete ==="
