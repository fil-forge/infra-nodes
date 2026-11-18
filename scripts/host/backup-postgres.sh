#!/usr/bin/env bash
# Take a base backup of this node's Postgres and push it to the backup target.
#
# WAL-G runs inside the Postgres container, as its postgres user, with the
# config every reconcile pass renders from filone/backup-target. It streams the
# data directory up as tar partitions under
# <key_prefix>postgres/<system identifier>/basebackups_005/, beside the WAL that
# archive_command sends to <key_prefix>postgres/<system identifier>/wal_005/. A
# point-in-time restore needs a base backup from before the moment it restores
# to and every WAL segment after it, so the WAL is only as useful as the newest
# base backup it follows.
#
# The backup key can write, and read only the timeline history files WAL-G
# looks for under its own prefix. It cannot delete a backup or change a locked
# version, but a put to an existing key adds a newer current version (central's
# docs/decisions/2026-11-appliance-backup-target.md). The bucket locks each
# object for central's appliance_backups.retention_days, 35 days on staging,
# and then expires it, so old base backups and the WAL after them age out
# together.
#
# Runs from filone-postgres-backup.timer once a day. deploy-platform.sh enables
# the timer once the platform runs with archiving on, and every reconcile pass
# starts a run while the running cluster has no base backup of its own. Run it
# by hand, as root, to take one now. Runs take a lock of their own,
# so one started by hand waits for the timer's rather than overlapping it.
#
# Usage:
#   scripts/host/backup-postgres.sh
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

case "${1:-}" in
  "") ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0 ;;
  *) die "unknown option: $1" ;;
esac

filone_init

if ! node_takes_backups; then
  echo "  $FILONE_NODE_DIR/node.env sets FILONE_TAKES_BACKUPS=false; no base backup taken"
  exit 0
fi

# Under the unit's TimeoutStartSec, which is far longer.
backup_lock_wait=600
install -d -m 0700 /run/fil-one
exec 7>/run/fil-one/postgres-backup.lock
flock -w "$backup_lock_wait" 7 ||
  die "another Postgres base backup has run for over ${backup_lock_wait}s.
       'fuser -v /run/fil-one/postgres-backup.lock' names the process holding it."

container_running "$FILONE_POSTGRES_CONTAINER" ||
  die "$FILONE_POSTGRES_CONTAINER is not running, so there is nothing to back up"
walg_installed ||
  die "WAL-G ${WALG_VERSION:-(no pin in node.env)} is not installed at $(walg_binary).
       Run scripts/host/install-tools.sh."
# WAL-G takes a base backup with archiving off, warning only, and it would
# stamp a fresh backup that no archived WAL can be replayed onto.
archiving="$(postgres_archive_mode)" ||
  die "could not read archive_mode from $FILONE_POSTGRES_CONTAINER"
[ "$archiving" = on ] ||
  die "Postgres runs with archive_mode=$archiving, so a base backup would have no WAL to
       restore with. $FILONE_NODE_DIR/platform/versions.env turns archiving on beside the
       Debian image."
# The cluster this backup is of, which also names the archive it goes to.
sysid="$(postgres_system_identifier)" ||
  die "could not read the Postgres cluster's system identifier"

# Render it here as well as in reconcile, so a run by hand right after a boot
# does not wait for a pass.
write_walg_config

echo "=== Postgres base backup ($FILONE_NODE) ==="
# Bounded inside the container, under the unit's TimeoutStartSec: systemd's
# timeout kills the docker exec client here, which would leave WAL-G running in
# the container, past the lock, into the next day's run.
docker exec -u postgres "$FILONE_POSTGRES_CONTAINER" \
  timeout --kill-after=5m 690m \
  "/opt/wal-g/$WALG_VERSION/wal-g" --config "/etc/wal-g/$sysid.json" backup-push /var/lib/postgresql/data ||
  die "WAL-G could not push the base backup; its output above says why.
       scripts/host/check-backup-target.sh tests the key and the target on their own."

stamp_postgres_backup_success "$sysid"
echo "=== base backup uploaded ==="
