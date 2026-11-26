#!/usr/bin/env bash
# Make the node match the ref it tracks. Deploy only what changed, and a
# project with a container that should be running and is not.
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
# And it deploys a project with a container that should be running and is not,
# so a container stopped by hand, or removed, comes back within five minutes
# whether or not anything was merged. Stopping filone-reconcile.timer is how an
# operator keeps one down; docs/RUNBOOK.md says how.
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
# A container that should be running and is not: stopped by hand, killed, or
# removed. No commit changed, so nothing above notices, and Docker's restart
# policy never starts a container someone stopped. The deploy scripts start it
# the way they start one on any pass; for a Piri or Ingot that means rendering
# their keys and config first. Bucket Intelligence's two are deploy-rag.sh's.
log_stopped() {
  local project="$1" stopped="$2" service state
  while read -r service state; do
    if [ "$state" = missing ]; then
      echo "  $project: $service has no container; deploying $project to start it"
    else
      echo "  $project: $service is not running ($state); deploying $project to start it"
    fi
  done <<<"$stopped"
}
if [ "$deploy_platform" -eq 0 ]; then
  stopped="$(stopped_services platform)"
  if [ -n "$stopped" ]; then
    log_stopped platform "$stopped"
    deploy_platform=1
  fi
fi
if [ "$deploy_apps" -eq 0 ]; then
  core_services="$(apps_core_services)"
  # shellcheck disable=SC2086 # one service name per word
  stopped="$(stopped_services apps $core_services)"
  if [ -n "$stopped" ]; then
    log_stopped apps "$stopped"
    deploy_apps=1
  fi
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
# The same for the import service, whose deploy-import.sh never starts, stops
# or recreates any other container either.
retry_import=0
if [ "$deploy_apps" -eq 0 ] && [ -e "$FILONE_STATE_DIR/import-retry" ]; then
  echo "  the import service has a deploy to retry"
  retry_import=1
fi

# --- 4. Renew the local OpenBao token ---------------------------------------

# Every pass, including a pass that deploys nothing, because a node can go days
# without a platform commit and the token's period is shorter than that. While
# OpenBao's container is not running, both renewals are left to the platform
# deploy this pass makes to start it, which renews once OpenBao is up. A renewal
# here would fail the pass before that deploy could run.
if container_running "$FILONE_BAO_CONTAINER"; then
  renew_bao_token

  # After the host token, so a node that has no region token yet still keeps
  # its host token alive. Every five minutes against a 72h period, which leaves
  # plenty of room: a reconcile stalled for three days is already alarmed
  # through deploy_last_success_timestamp.
  renew_ingot_regionkey_token
fi

# --- 5. Deploy --------------------------------------------------------------

# From the checkout, not from the copy this script re-exec'd out of. A commit
# that fixes a deploy script has to take effect on the pass that pulls it: the
# checkout HEAD has already moved, so a later pass sees nothing to do.
#
# A failed platform deploy does not skip the apps. A platform service that is
# broken until someone steps in, an Alloy with a bad config say, must not keep
# every Piri and Ingot down with it. Where what failed is something the apps
# need, OpenBao or Postgres, the apps deploy fails on its own. The pass still
# fails at the end, so it is retried and stamps no success.
platform_failed=0
if [ "$deploy_platform" -eq 1 ]; then
  echo "==> deploying platform"
  if ! "$FILONE_CHECKOUT/scripts/host/deploy-platform.sh"; then
    echo "WARNING: the platform deploy failed; deploying the apps anyway" >&2
    platform_failed=1
  fi
fi

if [ "$deploy_apps" -eq 1 ]; then
  echo "==> deploying apps"
  "$FILONE_CHECKOUT/scripts/host/deploy-apps.sh"
else
  # A failure is logged as a warning and leaves the marker for the next pass.
  # It does not fail this one: Piri and Ingot are not involved.
  if [ "$retry_rag" -eq 1 ]; then
    echo "==> retrying Bucket Intelligence"
    "$FILONE_CHECKOUT/scripts/host/deploy-rag.sh" || true
  fi
  if [ "$retry_import" -eq 1 ]; then
    echo "==> retrying the import service"
    "$FILONE_CHECKOUT/scripts/host/deploy-import.sh" || true
  fi
fi

if [ "$deploy_platform" -eq 0 ] && [ "$deploy_apps" -eq 0 ] && [ "$retry_rag" -eq 0 ] &&
  [ "$retry_import" -eq 0 ]; then
  echo "  nothing to deploy"
fi

# Every pass on a node where the import service has a container, or has come up
# healthy, whose deploy records its configuration hash. Its port is open to
# every address whenever its firewall table is gone, and deploy-import.sh loads
# the table only when it runs. The container counts as well as the hash because
# a deploy forgets the hash as soon as it renders a changed file, so a render
# or pull that fails after that leaves the old container running without one.
# When Docker cannot say whether the container exists, the hash alone decides.
#
# The script loads nothing when the table matches the list. A failure that
# leaves the table loaded, such as a refused edit to the list, is a warning, as
# for the service's own deploy: the loaded table stays in force as it is, which
# is the last list applied unless its client set was changed by hand, and Piri
# and Ingot are not involved. A failure that leaves no table stops the service,
# so its port is never open to every address. That fires the container alert,
# and the retry marker has the next pass run deploy-import.sh, which loads the
# table before it starts the service again. The service is stopped before the
# marker is written, so a marker that cannot be written still leaves the port
# closed. A node set back to placeholders has no container, since
# deploy-import.sh removes it, and there is nothing to stop. The container is
# named in nodes/<node>/apps/compose.yml.
import_deployed=0
if [ -e "$FILONE_STATE_DIR/apps-import-service.sha256" ] ||
  container_exists filone-import-service; then
  import_deployed=1
fi
if [ "$import_deployed" -eq 1 ] && ! "$FILONE_CHECKOUT/scripts/host/import-firewall.sh"; then
  if "$FILONE_CHECKOUT/scripts/host/import-firewall.sh" loaded; then
    echo "WARNING: the import service's firewall table could not be applied; the loaded table stays in force as it is. import-firewall.sh status says what it admits. See above." >&2
  else
    echo "WARNING: the import service's firewall table is gone and could not be loaded; stopping the import service so its port is not open to every address. See above." >&2
    import_status=0
    container_exists filone-import-service || import_status=$?
    case "$import_status" in
      0)
        docker stop filone-import-service >/dev/null ||
          die "could not stop filone-import-service, whose port is open to every address"
        ;;
      1) echo "  filone-import-service does not exist; nothing to stop" ;;
      *) die "could not ask Docker whether filone-import-service exists, whose port may be open to every address" ;;
    esac
    touch "$FILONE_STATE_DIR/import-retry" ||
      die "could not write $FILONE_STATE_DIR/import-retry, which has the next pass load the firewall table"
  fi
fi

[ "$platform_failed" -eq 0 ] || die "the platform deploy failed; its output above says why"

# Stamped on every pass that gets this far, including a pass that deployed
# nothing. That is what makes it a deadman: the metric goes stale when the node
# stops reconciling, whether or not anyone was shipping.
stamp_deploy_success reconcile

# Every pass, so a write whose snapshot failed, or one made by a script that
# does not ask for a snapshot itself, goes up within five minutes rather than
# at the next daily run.
request_openbao_snapshot
echo "=== reconcile complete ==="
