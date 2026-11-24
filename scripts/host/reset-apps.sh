#!/usr/bin/env bash
# Wipe Piri's and Ingot's state on a node, and keep everything that identifies
# the node. For dev and staging. Production is refused unless --production is
# given, for a production stage that holds nothing worth keeping.
#
# Wiped: the ingot database, every Piri database (piri on a one-Piri node,
# piri_0, piri_1 and so on after the move to one Piri per volume), and the
# contents of each app's data directory. That is the blobs, Ingot's local state
# and the config `piri init` writes; the next init writes a fresh one and
# creates a new proof set, because it looks proof sets up in its own database.
#
# Kept: the control volume's OpenBao and its unseal token at
# /etc/fil-one/seal-token, every key, wallet and DID in the node's OpenBao, and
# the stored hilt-to-ingot delegation. The databases come back empty with the
# same roles and passwords, so nothing has to be rendered again.
#
# This is the node half of an app reset. Central is reset after it, and the apps
# stay stopped here until then, with filone-reconcile.timer disabled so no pass
# starts them: the next deploy-apps.sh brings them back, each Piri then has to
# be onboarded again, and the operator enables the timer. infra-central's docs/reset-apps.md
# has the whole order.
#
# On a node whose Ingot keeps its catalog log on a filesystem of its own, bound
# over the data directory's segments folder, that filesystem is not emptied. The
# reset stops before it changes anything when it holds data.
#
# Not touched either: blobs a Piri keeps in object storage instead of its data
# directory.
#
# Usage:
#   scripts/host/reset-apps.sh [--yes]
#   scripts/host/reset-apps.sh --production
#
# --production allows the reset on the prod stage. The confirmation is always
# asked for there: --yes is refused with it.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

POSTGRES_CONTAINER=filone-platform-postgres-1
APP_DATABASE_PATTERN='^(ingot|piri|piri_[0-9]+)$'

usage() {
  awk 'NR == 1 { next } /^set -euo/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

# The app databases that exist now. No docker exec in this script takes -i:
# the loops read their lines from stdin, and an exec with stdin attached would
# swallow the rest of them.
app_databases() {
  docker exec "$POSTGRES_CONTAINER" psql -U admin -d admin -v ON_ERROR_STOP=1 -At \
    -c "SELECT datname FROM pg_database WHERE datname ~ '$APP_DATABASE_PATTERN' ORDER BY datname"
}

# The host directory a container mounts its data from, resolved and checked
# before anything is deleted in it. Only the data roots of the two layouts pass:
# /mnt/fil-one on the cloud nodes, and /mnt/data/fil-one and /var/lib/fil-one
# (Ingot) on the bare-metal nodes, at a path is_app_data_dir accepts. The
# control volume is under the first root and holds Postgres and OpenBao, so it
# is refused by name.
checked_data_dir() {
  local container="$1" source_dir="$2" resolved
  resolved="$(readlink -f -- "$source_dir")" ||
    die "$container mounts $source_dir, which does not resolve"
  if [ -z "$resolved" ] || [ "$resolved" = / ]; then
    die "$container mounts $source_dir, which resolves to '$resolved'"
  fi
  [ -d "$resolved" ] || die "$container mounts $resolved, which is not a directory"

  case "$resolved" in
    "$FILONE_CONTROL_DIR" | "$FILONE_CONTROL_DIR"/*)
      die "$container mounts $resolved, on the control volume; refusing to empty it" ;;
    /mnt/fil-one/* | /mnt/data/fil-one/* | /var/lib/fil-one/*) ;;
    *) die "$container mounts $resolved, outside /mnt/fil-one, /mnt/data/fil-one and /var/lib/fil-one; refusing to empty it" ;;
  esac
  is_app_data_dir "$resolved" ||
    die "$container mounts $resolved, which is not named for an app; refusing to empty it"

  printf '%s' "$resolved"
}

assume_yes=0
production=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) assume_yes=1 ;;
    --production) production=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (usage: reset-apps.sh [--yes] | --production)" ;;
  esac
  shift
done

filone_init

case "$STAGE" in
  dev | staging)
    [ "$production" -eq 0 ] || die "--production is for the prod stage; this node's stage is '$STAGE'"
    ;;
  prod)
    [ "$production" -eq 1 ] ||
      die "refusing to reset the apps on stage 'prod' without --production"
    [ "$assume_yes" -eq 0 ] ||
      die "--yes is refused with --production; the confirmation is always asked for on prod"
    ;;
  *) die "refusing to reset the apps on stage '$STAGE'; only dev, staging and prod can be reset" ;;
esac

# Before anything is stopped: postgres-init interpolates its passwords from
# platform.env, which only a platform deploy writes into the tmpfs. A node that
# rebooted since has none, and the reset would stop with the databases dropped.
[ -s "$FILONE_SECRETS_DIR/platform.env" ] ||
  die "$FILONE_SECRETS_DIR/platform.env is missing; run deploy-platform.sh first"
container_running "$POSTGRES_CONTAINER" ||
  die "$POSTGRES_CONTAINER is not running; run deploy-platform.sh first"

# A reconcile pass that deployed apps halfway through would start Piri against a
# database that is about to be dropped.
take_deploy_lock

echo "=== reset apps ($FILONE_NODE, $STAGE) ==="

# Every Piri on the box, whichever layout it runs, then Ingot. Read from Docker
# so a stopped container counts too, which is what a rerun after a failure finds.
container_names="$(docker ps -a --format '{{.Names}}')" || die "could not list containers"
app_containers="$(grep -E '^filone-piri(-[0-9]+)?$' <<<"$container_names" | sort -V || true)"
if grep -qx filone-ingot <<<"$container_names"; then
  app_containers+="${app_containers:+$'\n'}filone-ingot"
fi
[ -n "$app_containers" ] || die "no filone-piri* or filone-ingot container on this box; nothing to reset"

# Where each data directory is on the host, read off the container before it is
# stopped. The compose file is not asked: the containers are what was deployed,
# and the checkout may already be ahead of them.
declare -A data_dirs=()
while read -r container; do
  if [ "$container" = filone-ingot ]; then
    destination=/data
  else
    destination=/data/piri
  fi
  source_dir="$(docker inspect \
    -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{.Source}}{{end}}{{end}}" \
    "$container")" || die "could not inspect $container"
  [ -n "$source_dir" ] || die "$container has nothing mounted at $destination"
  data_dirs[$container]="$(checked_data_dir "$container" "$source_dir")"
done <<<"$app_containers"

# Ingot's catalog log, where it has a filesystem of its own. The emptying below
# stays on the data directory's filesystem and would leave the log behind, so a
# log with anything in it stops the reset here, before anything is changed.
if grep -qx filone-ingot <<<"$app_containers"; then
  segments_dir="$(docker inspect \
    -f '{{range .Mounts}}{{if eq .Destination "/data/segments"}}{{.Source}}{{end}}{{end}}' \
    filone-ingot)" || die "could not inspect filone-ingot"
  if [ -n "$segments_dir" ]; then
    leftover="$(find "$segments_dir" -mindepth 1 ! -name lost+found -print -quit)" ||
      die "could not look in $segments_dir"
    [ -z "$leftover" ] ||
      die "filone-ingot keeps its catalog log in $segments_dir, a mount of its own that this
       reset does not empty, and it holds data ($leftover). Nothing was changed."
  fi
fi

databases="$(app_databases)" || die "could not list the databases in $POSTGRES_CONTAINER"

echo "  containers to stop, and the data directories to empty:"
while read -r container; do
  echo "    $container  ${data_dirs[$container]}"
done <<<"$app_containers"
echo "  databases to drop and recreate empty:"
if [ -n "$databases" ]; then
  # shellcheck disable=SC2086 # one database name per word
  printf '    %s\n' $databases
else
  echo "    none left; postgres-init creates them"
fi
echo "  kept: OpenBao, the seal token, every key and wallet, the hilt proof"

if [ "$assume_yes" -eq 0 ]; then
  [ -t 0 ] || die "no terminal to confirm on; pass --yes to reset without asking"
  echo
  read -rp "Type reset-$STAGE to continue: " answer
  [ "$answer" = "reset-$STAGE" ] || die "not confirmed; nothing was changed"
fi

echo "[1/4] Stopping the apps"
# Reconcile starts any app container that is not running, so it is kept off
# until central is reset too. Disabled, so a reboot in between does not start
# it again, and stopped whether or not it was enabled: a timer started by hand
# without being enabled is active all the same. With the deploy lock held no
# pass is past the point where it takes the lock, so stopping the service cuts
# none off mid-deploy and cancels a retry systemd queued after a failed one.
if systemctl is-enabled --quiet filone-reconcile.timer 2>/dev/null; then
  systemctl disable --now filone-reconcile.timer >/dev/null 2>&1 ||
    die "could not disable filone-reconcile.timer"
  echo "  disabled filone-reconcile.timer"
fi
if systemctl is-active --quiet filone-reconcile.timer 2>/dev/null; then
  systemctl stop filone-reconcile.timer || die "could not stop filone-reconcile.timer"
  echo "  stopped filone-reconcile.timer"
fi
systemctl stop filone-reconcile.service 2>/dev/null || true
if ! stop_apps; then
  echo "  the apps were already stopped"
fi
# stop_apps on a lib.sh from before the move knows only filone-piri. Stop the
# rest here, since emptying the directory of a running Piri corrupts it.
while read -r container; do
  if container_running "$container"; then
    echo "  stopping $container"
    docker stop "$container" >/dev/null || die "could not stop $container"
  fi
done <<<"$app_containers"

echo "[2/4] Dropping the databases"
# WITH (FORCE) terminates the remaining connections first. The apps are stopped,
# so any left are a psql session someone forgot about.
while read -r database; do
  [ -n "$database" ] || continue
  docker exec "$POSTGRES_CONTAINER" psql -U admin -d admin -v ON_ERROR_STOP=1 --quiet \
    -c "DROP DATABASE IF EXISTS \"$database\" WITH (FORCE)" ||
    die "could not drop database $database"
  echo "  dropped $database"
done <<<"$databases"

echo "[3/4] Recreating them with postgres-init"
# --no-deps so a platform change the checkout has not deployed yet cannot
# recreate Postgres underneath the reset. --force-recreate so the one-shot runs
# again even when its definition has not changed.
compose_platform up -d --no-deps --force-recreate postgres-init ||
  die "could not start postgres-init"
init_container="$(compose_platform ps -aq postgres-init)"
[ -n "$init_container" ] || die "postgres-init has no container"
init_status="$(docker wait "$init_container")" || die "could not wait for postgres-init"
if [ "$init_status" != 0 ]; then
  docker logs --tail 50 "$init_container" >&2 || true
  die "postgres-init exited $init_status"
fi
databases="$(app_databases)" || die "could not list the databases in $POSTGRES_CONTAINER"
[ -n "$databases" ] || die "postgres-init succeeded and created no app database"
# shellcheck disable=SC2086 # one database name per word
printf '  %s\n' $databases

echo "[4/4] Emptying the data directories"
# The directory itself stays: Docker refuses to start a Piri whose directory is
# missing. lost+found belongs to a filesystem whose root is emptied. -xdev keeps
# the find from following a mount someone put further down.
while read -r container; do
  data_dir="${data_dirs[$container]}"
  find "$data_dir" -xdev -mindepth 1 -maxdepth 1 ! -name lost+found \
    -exec rm -rf --one-file-system -- {} + ||
    die "could not empty $data_dir"
  echo "  emptied $data_dir"
done <<<"$app_containers"

echo
echo "=== apps reset; they stay stopped ==="
echo "filone-reconcile.timer is disabled, so nothing starts them early."
echo "Next: reset central (make reset-apps in infra-central), then run"
echo "deploy-apps.sh, which starts them again, and onboard each Piri."
echo "Then: systemctl enable --now filone-reconcile.timer"
