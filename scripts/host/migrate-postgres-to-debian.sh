#!/usr/bin/env bash
# Move this node's Postgres from the Alpine image to the Debian one, by dumping
# every database out of the old cluster and restoring it into a new one.
#
# Why not point the Debian image at the old data directory: the old cluster was
# initialised with en_US.utf8, which the Alpine image's musl sorts in byte order
# and the Debian image's glibc sorts by language. Every text index in it is
# ordered for musl, so under glibc lookups miss rows, and Postgres starts
# without a complaint because musl recorded no collation version to compare.
# The new cluster is initialised with C.UTF-8, which glibc sorts by code point:
# the same order the apps have had all along.
#
# Run it as root on the node, inside tmux or screen, once the change that moves
# the node's image has reached the checkout. From then on deploy-platform.sh
# refuses to run, naming this script. It pulls the new image, waits for Piri's
# proving gate, stops Piri and Ingot, dumps every database, starts the new
# cluster in the directory compose.yml now mounts, restores the dumps, compares
# every table's row count, and then runs deploy-platform.sh and starts the apps
# again. The apps are down for all of that; the databases' sizes, printed
# before it asks to continue, say for how long.
#
# The old directory is left as it was. If a step fails after the old cluster
# stopped, or the run is interrupted, the script starts the old cluster again
# under its old image and brings the apps back on it; the next run moves the
# half-built new directory aside first. A run killed outright (SIGKILL, a
# reboot) cannot do that, and deploy-apps.sh then refuses to start the apps on
# the half-built cluster: --rollback starts the old cluster and the apps.
# docs/RUNBOOK.md has the procedure and the way back after a migration that
# succeeded.
#
# Usage:
#   scripts/host/migrate-postgres-to-debian.sh [--yes]
#   scripts/host/migrate-postgres-to-debian.sh --rollback
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# The roles postgres-init makes, and the one the image's entrypoint makes. The
# new cluster gets these from the same places, with their passwords from
# OpenBao, so no password is written to a file here.
EXPECTED_ROLES="admin ingot piri"

usage() {
  awk 'NR == 1 { next } /^set -euo/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

mode=migrate
assume_yes=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) assume_yes=1 ;;
    --rollback) mode=rollback ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (usage: migrate-postgres-to-debian.sh [--yes | --rollback])" ;;
  esac
  shift
done

filone_init

# No docker exec here takes -t, so a dump's bytes reach the file unchanged, and
# only the restores take -i, for the dump they read on stdin.
psql_in() {
  docker exec "$FILONE_POSTGRES_CONTAINER" \
    psql -U admin -d "$1" -v ON_ERROR_STOP=1 -At -c "$2"
}

# Every table's exact row count, one "schema.table count" per line, sorted. Run
# against both clusters and compared.
row_counts() {
  psql_in "$1" "
    SELECT format('%I.%I %s', table_schema, table_name,
                  (xpath('/row/c/text()',
                         query_to_xml(format('SELECT count(*) AS c FROM %I.%I',
                                             table_schema, table_name),
                                      false, true, '')))[1]::text)
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE'
      AND table_schema NOT IN ('pg_catalog', 'information_schema')
    ORDER BY 1"
}

[ -s "$FILONE_SECRETS_DIR/platform.env" ] && [ -s "$FILONE_SECRETS_DIR/openbao.env" ] ||
  die "the platform's rendered secrets are missing from $FILONE_SECRETS_DIR. Run
       scripts/host/deploy-platform.sh, which renders them before it refuses."

# A reconcile pass in the middle of this would find the marker missing and stop,
# but an apps deploy would start Piri against a cluster on its way down.
take_deploy_lock

previous="$(postgres_previous_data_dir)"
configured="$(postgres_data_dir)" ||
  die "could not read Postgres's data directory from $FILONE_NODE_DIR/platform/compose.yml"
marker="$(postgres_migrated_marker)"
workdir="$FILONE_CONTROL_DIR/postgres-migration"
# The image the old cluster ran under, written before anything is stopped, so a
# rollback can start it again after a run that died without undoing itself.
old_image_file="$workdir/old-image"
log="$FILONE_STATE_DIR/migrate-postgres.log"

# Bash runs the EXIT trap after a fatal signal with a status of 0, which would
# read as success and skip the undo below. Exiting from a trap of their own
# hands it the signal's status instead. A hangup has also taken the terminal, so
# what the undo prints goes to a log.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exec >>"$log" 2>&1; echo "terminal hung up at $(date -u +%Y-%m-%dT%H:%M:%SZ)"; exit 129' HUP

[ "$configured" != "$previous" ] ||
  die "compose.yml still mounts $previous. Run this once the change that moves this
       node to the Debian image has reached the checkout."
[ -f "$previous/PG_VERSION" ] || die "there is no cluster in $previous"
[ "$(cat "$marker" 2>/dev/null)" != "$configured" ] ||
  die "$marker says this node was already migrated into $configured. After a
       finished migration the way back is a revert; docs/RUNBOOK.md says how."
case "$configured" in
  "$FILONE_CONTROL_DIR"/*) ;;
  *) die "compose.yml mounts $configured, outside $FILONE_CONTROL_DIR; refusing to build a cluster there" ;;
esac

# Start the old cluster again from its own directory under the image it ran
# before. The shell's values win over the env files', so this one start uses
# them while compose.yml keeps the new ones, and the deploy-platform.sh guard
# leaves the cluster alone until a migration finishes. Returns non-zero rather
# than dying, for the undo below.
start_old_cluster() {
  local image="$1"
  echo "  starting the old cluster again under $image"
  POSTGRES_IMAGE="$image" POSTGRES_DATA_DIR="$previous" \
    compose_platform up -d --no-deps --force-recreate postgres || return 1
  ( wait_healthy compose_platform 300 postgres ) || return 1
}

old_cluster_running() {
  container_running "$FILONE_POSTGRES_CONTAINER" &&
    [ "$(readlink -f -- "$(postgres_container_data_dir)")" = "$(readlink -f -- "$previous")" ]
}

# --- Rolling back a run that died ---------------------------------------------

if [ "$mode" = rollback ]; then
  [ -s "$old_image_file" ] ||
    die "$old_image_file is missing: no run of this script stopped the old cluster,
       or one already put it back"
  echo "=== put the old Postgres cluster back ($FILONE_NODE) ==="
  if old_cluster_running; then
    echo "  the old cluster is already running"
  else
    start_old_cluster "$(cat "$old_image_file")" || die "could not start the old cluster"
  fi
  start_apps
  rm -rf -- "$workdir"
  echo "=== the old cluster is back, and Piri and Ingot run on it ==="
  exit 0
fi

# --- What the old cluster holds ------------------------------------------------

old_cluster_running ||
  die "$FILONE_POSTGRES_CONTAINER is not running on $previous, and the old cluster has
       to be running to be dumped. If a run of this script died partway, run it with
       --rollback first."
old_image="$(docker inspect -f '{{.Config.Image}}' "$FILONE_POSTGRES_CONTAINER")" ||
  die "could not read the image $FILONE_POSTGRES_CONTAINER runs"

echo "=== migrate Postgres to the Debian image ($FILONE_NODE) ==="

# Each of these would be lost or refused by the restore, so they stop the
# migration before anything is changed.
roles="$(psql_in admin "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY 1")" ||
  die "could not list the roles in the old cluster"
extra_roles="$(comm -23 <(sort <<<"$roles") <(tr ' ' '\n' <<<"$EXPECTED_ROLES" | sort))"
[ -z "$extra_roles" ] ||
  die "the old cluster has roles postgres-init does not make: $(tr '\n' ' ' <<<"$extra_roles")
       The new cluster would not have them. Drop them, or extend this script."
check_none() {
  local what="$1" query="$2" count
  count="$(psql_in admin "$query")" || die "could not check the old cluster for $what"
  [ "$count" = 0 ] || die "the old cluster has $count $what, which this script does not carry across"
}
check_none "app roles with attributes postgres-init does not give them" \
  "SELECT count(*) FROM pg_roles WHERE rolname IN ('ingot', 'piri') AND (rolsuper OR rolcreaterole
   OR rolcreatedb OR rolreplication OR rolbypassrls OR NOT rolinherit OR rolconnlimit <> -1
   OR rolvaliduntil IS NOT NULL)"
check_none "role memberships" \
  "SELECT count(*) FROM pg_auth_members WHERE pg_get_userbyid(member) !~ '^pg_'"
check_none "ALTER ROLE or ALTER DATABASE ... SET entries" "SELECT count(*) FROM pg_db_role_setting"
check_none "ALTER SYSTEM settings" \
  "SELECT count(*) FROM pg_file_settings WHERE sourcefile LIKE '%/postgresql.auto.conf'"
check_none "tablespaces of its own" \
  "SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global')"
check_none "databases with GRANTs of their own" \
  "SELECT count(*) FROM pg_database WHERE datacl IS NOT NULL AND NOT datistemplate"

declare -A owners=() sizes=()
databases=()
total_bytes=0
while IFS='|' read -r name owner bytes; do
  [[ "$name" =~ ^[a-z0-9_]+$ ]] ||
    die "database '$name' has a name this script does not handle; rename it first"
  databases+=("$name")
  owners[$name]="$owner"
  sizes[$name]="$bytes"
  total_bytes=$((total_bytes + bytes))
done < <(psql_in admin "SELECT datname, pg_get_userbyid(datdba), pg_database_size(datname)
                        FROM pg_database WHERE NOT datistemplate ORDER BY datname")
[ "${#databases[@]}" -gt 0 ] || die "the old cluster lists no databases"

# The dumps and the new cluster both land on the control volume. A dump is
# smaller than its database, and the new cluster no larger than the old, so
# twice the databases' size is enough.
free_bytes="$(df --output=avail -B1 "$FILONE_CONTROL_DIR" | tail -1 | tr -d ' ')"
[ "$free_bytes" -ge $((2 * total_bytes)) ] ||
  die "$FILONE_CONTROL_DIR has $(numfmt --to=iec "$free_bytes") free; the dumps and the new
       cluster need up to $(numfmt --to=iec $((2 * total_bytes)))"

echo "  from $previous, under $old_image"
echo "  to   $configured, under the image versions.env names, with locale C.UTF-8"
echo "  databases:"
for name in "${databases[@]}"; do
  printf '    %-12s %8s  owner %s\n' "$name" "$(numfmt --to=iec "${sizes[$name]}")" "${owners[$name]}"
done
echo "  Piri and Ingot stay stopped until every database is restored and checked."
echo "  $previous is left as it was."

if [ "$assume_yes" -eq 0 ]; then
  [ -t 0 ] || die "no terminal to confirm on; pass --yes to migrate without asking"
  echo
  read -rp "Type migrate-$STAGE to continue: " answer
  [ "$answer" = "migrate-$STAGE" ] || die "not confirmed; nothing was changed"
fi

# --- Undoing a failed run -------------------------------------------------------

# 0: nothing changed yet. 1: the apps are stopped. 2: the old cluster is stopped
# too, so it has to come back before the apps do.
progress=0
# Without errexit, so that nothing in it, a write to a terminal that is gone
# included, cuts it short; what can die runs in a subshell.
undo() {
  local status=$?
  set +e
  [ "$status" -ne 0 ] || return 0
  if [ "$progress" -ge 2 ]; then
    echo "migration failed; putting the old cluster back" >&2
    if ! start_old_cluster "$old_image"; then
      echo "could not start the old cluster, so Piri and Ingot stay stopped. Fix the" >&2
      echo "cause, then run this script with --rollback." >&2
      return
    fi
  fi
  if [ "$progress" -ge 1 ]; then
    echo "bringing Piri and Ingot back up" >&2
    ( start_apps ) || echo "could not start every app; start them with deploy-apps.sh" >&2
  fi
  rm -rf -- "$workdir"
  echo "nothing was migrated; $previous is unchanged. Fix the cause and run this again." >&2
}
trap undo EXIT

# --- Dumping ------------------------------------------------------------------

echo "[1/6] Stopping Piri and Ingot"
# Before the gate, so the download is not part of the outage.
echo "  pulling the new image"
compose_platform pull --quiet postgres || die "could not pull the new Postgres image"
# Only this script writes here, so whatever an earlier run left is safe to clear.
rm -rf -- "$workdir"
install -d -m 0700 -o root -g root "$workdir"
printf '%s\n' "$old_image" >"$old_image_file"
piri_containers="$(piri_containers)"
if [ -n "$piri_containers" ]; then
  echo "  waiting for a safe restart window"
  # shellcheck disable=SC2086 # one service name per word
  "$SCRIPT_DIR/pdp-gate.sh" ${piri_containers//filone-/}
fi
progress=1
stop_apps || echo "  they were already stopped"

echo "[2/6] Dumping the old cluster"
for name in "${databases[@]}"; do
  docker exec "$FILONE_POSTGRES_CONTAINER" pg_dump -U admin -Fc -d "$name" \
    >"$workdir/$name.dump" || die "could not dump $name"
  row_counts "$name" >"$workdir/$name.before" || die "could not count the rows in $name"
  echo "  $name: $(numfmt --to=iec "$(stat -c %s "$workdir/$name.dump")") dumped," \
    "$(wc -l <"$workdir/$name.before") tables"
done

echo "[3/6] Starting the new cluster"
progress=2
docker stop "$FILONE_POSTGRES_CONTAINER" >/dev/null || die "could not stop the old cluster"
# A directory left by a failed run is moved aside, not deleted: nothing but this
# script writes there, but a cluster is not something to remove unasked.
if [ -e "$configured" ] && [ -n "$(ls -A -- "$configured")" ]; then
  aside="$configured.failed-$(date -u +%Y%m%dT%H%M%SZ)"
  mv -- "$configured" "$aside" || die "could not move $configured aside"
  echo "  moved what a failed run left in $configured to $aside"
fi
install -d -m 0700 "$configured"
compose_platform up -d --no-deps --force-recreate postgres || die "could not start the new cluster"
wait_healthy compose_platform 300 postgres
collation="$(psql_in admin "SELECT datcollate FROM pg_database WHERE datname = 'admin'")" ||
  die "could not read the new cluster's locale"
[ "$collation" = C.UTF-8 ] ||
  die "the new cluster was initialised with $collation, not C.UTF-8. Check
       POSTGRES_INITDB_ARGS in $FILONE_NODE_DIR/platform/compose.yml."

echo "[4/6] Creating the roles and databases"
compose_platform up -d --no-deps --force-recreate postgres-init ||
  die "could not start postgres-init"
init_container="$(compose_platform ps -aq postgres-init)"
[ -n "$init_container" ] || die "postgres-init has no container"
init_status="$(docker wait "$init_container")" || die "could not wait for postgres-init"
if [ "$init_status" != 0 ]; then
  docker logs --tail 50 "$init_container" >&2 || true
  die "postgres-init exited $init_status"
fi
for name in "${databases[@]}"; do
  exists="$(psql_in admin "SELECT count(*) FROM pg_database WHERE datname = '$name'")" ||
    die "could not look for database $name"
  if [ "$exists" = 0 ]; then
    psql_in admin "CREATE DATABASE \"$name\" OWNER \"${owners[$name]}\"" >/dev/null ||
      die "could not create database $name"
    echo "  created $name, which postgres-init does not make"
  fi
done

echo "[5/6] Restoring and checking"
for name in "${databases[@]}"; do
  # One transaction per database, so a restore that fails leaves nothing behind
  # in it. The owners are kept: the apps run their own migrations, and need to
  # own the tables they alter.
  docker exec -i "$FILONE_POSTGRES_CONTAINER" \
    pg_restore -U admin -d "$name" --exit-on-error --single-transaction \
    <"$workdir/$name.dump" || die "could not restore $name"
  docker exec "$FILONE_POSTGRES_CONTAINER" vacuumdb -U admin -d "$name" --analyze-only --quiet ||
    die "could not analyze $name"
  row_counts "$name" >"$workdir/$name.after" || die "could not count the rows in $name"
  if ! diff -u "$workdir/$name.before" "$workdir/$name.after" >&2; then
    die "the restored $name does not have the rows the old one had (diff above)"
  fi
  echo "  $name: $(wc -l <"$workdir/$name.after") tables, every row count matches"
done
# deploy-platform.sh recreates this container next, and Docker allows its
# shutdown ten seconds. Flushing the restore now keeps the shutdown checkpoint
# short, so the next start does not begin with crash recovery.
psql_in admin "CHECKPOINT" >/dev/null || die "could not checkpoint the new cluster"

# From the marker on, the new cluster is the node's, so a failure below starts
# the apps on it rather than going back. Nothing runs between the move and the
# new trap.
printf '%s\n' "$configured" >"$marker.tmp"
mv -f "$marker.tmp" "$marker"
finish_failed() {
  local status=$?
  set +e
  [ "$status" -ne 0 ] || return 0
  echo "the data is migrated, but finishing the deploy failed; starting Piri and" >&2
  echo "Ingot on the new cluster. The next reconcile pass retries the deploy." >&2
  ( start_apps ) || echo "could not start every app; start them with deploy-apps.sh" >&2
}
trap finish_failed EXIT
rm -rf -- "$workdir"

echo "[6/6] Finishing the platform deploy, then the apps"
"$SCRIPT_DIR/deploy-platform.sh"
start_apps
core_services="$(apps_core_services)"
# shellcheck disable=SC2086 # one service name per word
wait_healthy compose_apps 420 $core_services

trap - EXIT
echo
echo "=== Postgres migrated ==="
echo "$previous is no longer used. Keep it until the node has run normally for a"
echo "while, then remove it: docs/RUNBOOK.md has when, and the way back until then."
