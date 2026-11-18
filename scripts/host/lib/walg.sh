#!/usr/bin/env bash
# The Postgres WAL archive: WAL-G, inside the Postgres container, sends every
# WAL segment and a daily base backup to the backup bucket, on a node that
# takes backups.
#
# Sourced by lib.sh, never on its own. The functions here use lib.sh's
# variables and helpers, such as die, load_backup_target, write_secret_file
# and container_running, which are all defined by the time any of them is
# called.

# shellcheck shell=bash
# SC2154: filone_init reads the node's node.env, which sets WALG_VERSION and
# TARGET_PLATFORM, and load_backup_target assigns the backup_* variables.
# shellcheck disable=SC2154

# The postgres user of the Postgres image, which archive_command and
# backup-push run as, and so the owner of WAL-G's config.
FILONE_POSTGRES_UID=999

# A directory on tmpfs that compose.yml binds into the Postgres container
# whole. A bind of the config file itself would keep Postgres from starting
# after a reboot, until something had rendered the file again; a missing file
# only fails archive_command, which Postgres retries, holding the segment in
# pg_wal. Every reconcile pass renders it, so the archive resumes within one
# pass of a boot.
FILONE_WALG_DIR=/run/fil-one/walg
FILONE_WALG_CONFIG="$FILONE_WALG_DIR/walg.json"

FILONE_POSTGRES_BACKUP_SERVICE=filone-postgres-backup.service
FILONE_POSTGRES_BACKUP_TIMER=filone-postgres-backup.timer

# install-tools.sh installs each pinned WAL-G as <version>/wal-g under this
# directory, which compose.yml binds into the Postgres container as /opt/wal-g.
FILONE_WALG_LIB=/usr/local/lib/fil-one/wal-g

# The host's path to the WAL-G of the node's pin.
walg_binary() {
  printf '%s/%s/wal-g\n' "$FILONE_WALG_LIB" "${WALG_VERSION:-}"
}

# Whether the WAL-G of the node's pin is installed. The deploys only warn when
# it is not: archive_command then fails, keeping every segment in pg_wal, and
# the archive alert fires, while the platform and the apps carry on.
# install-tools.sh installs it; the deploys never download anything.
walg_installed() {
  [ -n "${WALG_VERSION:-}" ] && [ -x "$(walg_binary)" ]
}

warn_unless_walg_installed() {
  walg_installed && return 0
  echo "  WARNING: WAL-G ${WALG_VERSION:-(no pin in node.env)} is not installed at $(walg_binary)," \
    "so Postgres cannot archive WAL. Run scripts/host/install-tools.sh."
}

# Render WAL-G's config from filone/backup-target, where provision-backups.sh
# stored the key and its target, into the tmpfs directory compose.yml binds.
# The archive goes under the key prefix's postgres/, the place central's
# writer policy gives it. Readable by the container's postgres user alone.
write_walg_config() {
  local content
  load_backup_target
  install -d -m 0755 -o root -g root "$FILONE_WALG_DIR"
  # On stdin, so the secret is never in an argv.
  content="$(printf '%s\n' "$backup_bucket" "$backup_key_prefix" "$backup_aws_region" \
    "$backup_access_key_id" "$backup_secret_access_key" | python3 -c '
import json, sys

bucket, prefix, region, key_id, secret = sys.stdin.read().split("\n")[:5]
json.dump({
    "WALG_S3_PREFIX": "s3://%s/%spostgres" % (bucket, prefix),
    "AWS_REGION": region,
    "AWS_ACCESS_KEY_ID": key_id,
    "AWS_SECRET_ACCESS_KEY": secret,
    # For backup-push, over the local socket inside the container.
    "PGHOST": "/var/run/postgresql",
    "PGUSER": "admin",
}, sys.stdout, indent=2, sort_keys=True)
print()
')" || die "could not build WAL-G's config"
  unset backup_secret_access_key

  write_secret_file "$FILONE_WALG_CONFIG" "$content" || true
  unset content
  chown "$FILONE_POSTGRES_UID:$FILONE_POSTGRES_UID" "$FILONE_WALG_CONFIG" ||
    die "could not hand $FILONE_WALG_CONFIG to the Postgres container's user"
}

# Enable the daily base backup, and take the first one now, once the platform
# runs with archiving on. WAL is no use for a restore without a base backup to
# replay it onto, so the first one does not wait for the timer.
start_postgres_backups() {
  node_takes_backups || return 0
  systemctl is-enabled --quiet "$FILONE_POSTGRES_BACKUP_TIMER" 2>/dev/null && return 0

  # The unit may not be on the box yet when this runs by hand, before a
  # reconcile pass has installed the checkout's units.
  sync_systemd_units
  systemctl enable --now "$FILONE_POSTGRES_BACKUP_TIMER" >/dev/null ||
    die "could not enable $FILONE_POSTGRES_BACKUP_TIMER"
  echo "  $FILONE_POSTGRES_BACKUP_TIMER enabled; taking the first base backup now"
  systemctl start --no-block "$FILONE_POSTGRES_BACKUP_SERVICE" ||
    echo "  WARNING: could not start $FILONE_POSTGRES_BACKUP_SERVICE; the timer takes one within a day"
}

# Stamp a base backup that reached the backup bucket. The deadman for the base
# backups, in the shape of the OpenBao snapshot stamp.
stamp_postgres_backup_success() {
  local tmp
  mkdir -p "$FILONE_METRICS_DIR"
  tmp="$(mktemp "$FILONE_METRICS_DIR/.postgres-backup.XXXXXX")"
  {
    echo "# HELP postgres_basebackup_last_success_timestamp Unix time of the last Postgres base backup uploaded to the backup target."
    echo "# TYPE postgres_basebackup_last_success_timestamp gauge"
    echo "postgres_basebackup_last_success_timestamp $(date +%s)"
  } >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$FILONE_METRICS_DIR/postgres-backup.prom"
}

# Render WAL-G's config as write_walg_config does, warning instead of failing.
# For the reconcile pass and the platform deploy: Postgres runs without the
# config, archiving fails and alerts, and a problem with filone/backup-target
# must not keep the platform or the apps from deploying, the first deploy after
# a boot included.
refresh_walg_config() {
  ( write_walg_config ) && return 0
  echo "  WARNING: could not render WAL-G's config, so Postgres cannot archive WAL" \
    "until a later pass renders it. scripts/host/check-backup-target.sh tests the key."
}

# Write the WAL archiver's state for the textfile collector, from
# pg_stat_archiver and the segments waiting in pg_wal/archive_status. Every
# reconcile pass calls it, ahead of the deploys so that a failing deploy does
# not freeze it, and the figures are at most five minutes old.
#
# The archive alert reads the oldest waiting segment's age, which it computes
# from the segment's timestamp, so the age goes on growing even if these
# figures stop being refreshed. It does not read the failure count: Postgres
# counts only an archive_command that exits 1 to 125, and an archiver that a
# missing binary (126, 127) or a signal kills leaves the count alone while the
# segments pile up.
#
# Nothing is written while archiving is off, which it is until the node runs
# the Debian image, so a node never reports an archive it does not have; a
# file an earlier pass wrote is removed, so the alert does not read it.
stamp_postgres_archive() {
  local row on archived failed last_archived last_failed pending oldest tmp
  local prom="$FILONE_METRICS_DIR/postgres-archive.prom"
  node_takes_backups || return 0
  container_running "$FILONE_POSTGRES_CONTAINER" || return 0

  row="$(docker exec "$FILONE_POSTGRES_CONTAINER" psql -U admin -d admin -v ON_ERROR_STOP=1 -At -F ' ' -c "
    SELECT current_setting('archive_mode'), a.archived_count, a.failed_count,
           coalesce(extract(epoch FROM a.last_archived_time)::bigint, 0),
           coalesce(extract(epoch FROM a.last_failed_time)::bigint, 0),
           r.pending, coalesce(extract(epoch FROM r.oldest)::bigint, 0)
    FROM pg_stat_archiver a,
         (SELECT count(*) AS pending, min(modification) AS oldest
          FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready') r")" || {
    echo "  WARNING: could not read the WAL archiver's state from $FILONE_POSTGRES_CONTAINER"
    return 0
  }
  read -r on archived failed last_archived last_failed pending oldest <<<"$row"
  if [ "$on" != on ]; then
    rm -f "$prom"
    return 0
  fi

  mkdir -p "$FILONE_METRICS_DIR"
  tmp="$(mktemp "$FILONE_METRICS_DIR/.postgres-archive.XXXXXX")"
  {
    echo "# HELP postgres_wal_archived_total WAL segments archived since the archiver's statistics were last reset."
    echo "# TYPE postgres_wal_archived_total counter"
    echo "postgres_wal_archived_total $archived"
    echo "# HELP postgres_wal_archive_failed_total Failed attempts to archive a WAL segment since the statistics were last reset. Attempts that killed the archiver are not counted."
    echo "# TYPE postgres_wal_archive_failed_total counter"
    echo "postgres_wal_archive_failed_total $failed"
    echo "# HELP postgres_wal_last_archived_timestamp Unix time of the last WAL segment archived, 0 if none."
    echo "# TYPE postgres_wal_last_archived_timestamp gauge"
    echo "postgres_wal_last_archived_timestamp $last_archived"
    echo "# HELP postgres_wal_last_failed_timestamp Unix time of the last failed archive attempt, 0 if none."
    echo "# TYPE postgres_wal_last_failed_timestamp gauge"
    echo "postgres_wal_last_failed_timestamp $last_failed"
    echo "# HELP postgres_wal_archive_pending WAL segments waiting in pg_wal to be archived."
    echo "# TYPE postgres_wal_archive_pending gauge"
    echo "postgres_wal_archive_pending $pending"
    # Absent while nothing waits, so the alert has no age to read.
    if [ "$pending" -gt 0 ]; then
      echo "# HELP postgres_wal_archive_oldest_pending_timestamp Unix time the oldest WAL segment waiting to be archived became ready."
      echo "# TYPE postgres_wal_archive_oldest_pending_timestamp gauge"
      echo "postgres_wal_archive_oldest_pending_timestamp $oldest"
    fi
  } >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$prom"
}
