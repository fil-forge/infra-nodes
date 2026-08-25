#!/usr/bin/env bash
# Make the node match the ref it tracks, and deploy only what changed.
#
# Runs every five minutes from filone-reconcile.timer. This is how a change
# reaches a node: merge it, and within five minutes the node is running it.
#
# Deliberately narrow. It updates the checkout, works out which of the two
# compose projects the new commits touch, and calls the ordinary deploy scripts.
# It creates nothing, prompts for nothing, and holds no secret.
#
# Env overrides:
#   FILONE_GIT_REF   branch, tag or commit the node tracks, for this run
#                    only (default: FILONE_GIT_REF in /etc/filone/node.conf,
#                    or main)
set -euo pipefail

# Read before filone_init, which sources /etc/filone/node.conf and would
# overwrite an override passed on the command line with the persistent value.
git_ref_override="${FILONE_GIT_REF:-}"

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

# The node's own node.conf carries the ref it normally tracks; the environment
# wins for a single run, which is how a feature branch gets tested on a node
# without editing anything on the box.
REF="${git_ref_override:-${FILONE_GIT_REF:-main}}"

echo "=== reconcile ($FILONE_NODE) ==="

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

# --- 2. Work out what changed ----------------------------------------------

changed_paths="$(git -C "$FILONE_CHECKOUT" diff --name-only "$before" "$after")"

touches() {
  printf '%s\n' "$changed_paths" | grep -qE "$1"
}

deploy_platform=0
deploy_apps=0

if [ "$before" != "$after" ]; then
  # The shared helpers and the node's own non-secret configuration feed both
  # projects, so a change to either deploys both.
  if touches "^scripts/host/" || touches "^nodes/$FILONE_NODE/node\.env$"; then
    deploy_platform=1
    deploy_apps=1
  fi
  if touches "^nodes/$FILONE_NODE/platform/"; then deploy_platform=1; fi
  if touches "^nodes/$FILONE_NODE/apps/"; then deploy_apps=1; fi

  # Units are installed by cloud-init on a fresh box and by this branch on every
  # box after that.
  if touches "^systemd/"; then
    echo "  reinstalling systemd units"
    install -m 0644 "$FILONE_CHECKOUT"/systemd/*.service "$FILONE_CHECKOUT"/systemd/*.timer \
      /etc/systemd/system/
    systemctl daemon-reload
  fi
fi

# --- 3. Deploy --------------------------------------------------------------

if [ "$deploy_platform" -eq 1 ]; then
  echo "==> platform changed"
  "$FILONE_RECONCILE_COPY/deploy-platform.sh"
fi

if [ "$deploy_apps" -eq 1 ]; then
  echo "==> apps changed"
  "$FILONE_RECONCILE_COPY/deploy-apps.sh"
fi

if [ "$deploy_platform" -eq 0 ] && [ "$deploy_apps" -eq 0 ]; then
  echo "  nothing to deploy"
fi

# Stamped on every pass that gets this far, including a pass that deployed
# nothing. That is what makes it a deadman: the metric goes stale when the node
# stops reconciling, whether or not anyone was shipping.
stamp_deploy_success reconcile
echo "=== reconcile complete ==="
