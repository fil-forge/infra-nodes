#!/usr/bin/env bash
# Make the node match the ref it tracks, and deploy only what changed.
#
# Runs every five minutes from filone-reconcile.timer. This is how a change
# reaches a node: merge it, and within five minutes the node is running it.
#
# Deliberately narrow. It updates the checkout, works out which of the two
# compose projects the new commits touch, and calls the ordinary deploy scripts.
# It creates nothing and prompts for nothing. The one secret it touches is the
# node's own deploy token, which it renews and never prints.
#
# The ref it tracks is FILONE_GIT_REF in /etc/filone/node.conf, which is the
# only statement of it. Point a node at a feature branch by editing that file.
set -euo pipefail

# Reconcile replaces the very files it is executing from. Bash reads a script
# incrementally, so a `git reset --hard` partway through this one can leave the
# shell reading from a different file at a different offset. Re-exec from a copy
# before touching the checkout.
if [ -z "${FILONE_RECONCILE_COPY:-}" ]; then
  copy_dir="$(mktemp -d /run/filone-reconcile.XXXXXX)"
  cp -a "$(dirname "$(readlink -f "$0")")/." "$copy_dir/"
  FILONE_RECONCILE_COPY="$copy_dir" exec "$copy_dir/reconcile.sh" "$@"
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

# --- 3. Work out what changed ----------------------------------------------

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

  git -C "$FILONE_CHECKOUT" diff --name-only "$base" "$after" | grep -qE "$pattern"
}

deploy_platform=0
deploy_apps=0
if project_is_stale platform "$shared_paths|^nodes/$FILONE_NODE/platform/"; then deploy_platform=1; fi
if project_is_stale apps "$shared_paths|^nodes/$FILONE_NODE/apps/"; then deploy_apps=1; fi

# --- 4. Renew the local OpenBao token ---------------------------------------

# Every pass, including a pass that deploys nothing. deploy-platform.sh renews
# it too, but a node can go days without a platform commit, and the token's
# period is shorter than that.
renew_bao_token

# After the deploy token, so a node that has no region token yet still keeps its
# deploy token alive. Every five minutes against a 72h period, which leaves
# plenty of room: a reconcile stalled for three days is already alarmed through
# deploy_last_success_timestamp.
renew_ingot_regionkey_token

# --- 5. Deploy --------------------------------------------------------------

# From the checkout, not from the copy this script re-exec'd out of. A commit
# that fixes a deploy script has to take effect on the pass that pulls it: the
# checkout HEAD has already moved, so a later pass sees nothing to do.
if [ "$deploy_platform" -eq 1 ]; then
  echo "==> platform changed"
  "$FILONE_CHECKOUT/scripts/host/deploy-platform.sh"
fi

if [ "$deploy_apps" -eq 1 ]; then
  echo "==> apps changed"
  "$FILONE_CHECKOUT/scripts/host/deploy-apps.sh"
fi

if [ "$deploy_platform" -eq 0 ] && [ "$deploy_apps" -eq 0 ]; then
  echo "  nothing to deploy"
fi

# Stamped on every pass that gets this far, including a pass that deployed
# nothing. That is what makes it a deadman: the metric goes stale when the node
# stops reconciling, whether or not anyone was shipping.
stamp_deploy_success reconcile
echo "=== reconcile complete ==="
