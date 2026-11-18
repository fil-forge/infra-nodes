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
# whole, as /etc/wal-g, holding the config of the running cluster as
# <system identifier>.json. A bind of a file would keep Postgres from starting
# after a reboot, until something had rendered the file again; a missing file
# only fails archive_command, which Postgres retries, holding the segment in
# pg_wal. Every reconcile pass renders it, so the archive resumes within one
# pass of a boot.
FILONE_WALG_DIR=/run/fil-one/walg

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

# The system identifier of the node's Postgres cluster: initdb picks it, and it
# stays with the cluster for life, through restarts, restores and a standby's
# promotion. Read from the first eight bytes of global/pg_control, in the host's
# byte order as Postgres wrote it, so it answers while Postgres is down too.
# The directory is the running container's, else the one compose.yml mounts.
postgres_system_identifier() {
  local dir sysid
  dir="$(postgres_container_data_dir 2>/dev/null || true)"
  [ -n "$dir" ] || dir="$(postgres_data_dir)" || return 1
  [ -r "$dir/global/pg_control" ] || return 1
  sysid="$(od -An -t u8 -N8 "$dir/global/pg_control" | tr -d ' ')" || return 1
  [[ "$sysid" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$sysid"
}

# Render WAL-G's config from filone/backup-target, where provision-backups.sh
# stored the key and its target, into the tmpfs directory compose.yml binds.
# The archive goes under the key prefix's postgres/, the place central's
# writer policy gives it, in a directory named for the cluster's system
# identifier. A cluster initialised again, on a node rebuilt after losing its
# control volume or migrated again, starts its WAL at the same segment names
# as the one before it; under one prefix its uploads would become the current
# versions of the old cluster's segments, and a restore of the old cluster
# would read them. The file is named for the identifier too, and Postgres's
# archive_command (config/postgres/wal-push.sh in the node's platform) reads
# the one named for the cluster it runs, so a config left from an earlier
# cluster is never used for a later one. Configs of other clusters are removed.
# Readable by the container's postgres user alone.
write_walg_config() {
  local content sysid config stale
  load_backup_target
  sysid="$(postgres_system_identifier)" ||
    die "could not read the Postgres cluster's system identifier, which names its archive;
       Postgres may not have initialised its cluster yet"
  install -d -m 0755 -o root -g root "$FILONE_WALG_DIR"
  # On stdin, so the secret is never in an argv.
  content="$(printf '%s\n' "$backup_bucket" "$backup_key_prefix" "$sysid" "$backup_aws_region" \
    "$backup_access_key_id" "$backup_secret_access_key" | python3 -c '
import json, sys

bucket, prefix, sysid, region, key_id, secret = sys.stdin.read().split("\n")[:6]
json.dump({
    "WALG_S3_PREFIX": "s3://%s/%spostgres/%s" % (bucket, prefix, sysid),
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

  config="$FILONE_WALG_DIR/$sysid.json"
  write_secret_file "$config" "$content" || true
  unset content
  chown "$FILONE_POSTGRES_UID:$FILONE_POSTGRES_UID" "$config" ||
    die "could not hand $config to the Postgres container's user"
  for stale in "$FILONE_WALG_DIR"/*.json; do
    [ "$stale" = "$config" ] || rm -f -- "$stale"
  done
}

# The archive_mode the running Postgres reports, or a failure when it cannot
# be asked.
postgres_archive_mode() {
  docker exec "$FILONE_POSTGRES_CONTAINER" psql -U admin -d admin -At -c 'SHOW archive_mode' 2>/dev/null
}

# Where backup-postgres.sh records the system identifier of the cluster its
# last successful base backup was of. A function, since filone_init sets the
# state directory after this file is sourced.
postgres_backup_cluster_file() {
  printf '%s/postgres-basebackup-cluster\n' "$FILONE_STATE_DIR"
}

# At the end of every platform deploy and every reconcile pass: enable the
# daily base backup while Postgres archives, and ask for the first one; disable
# it while Postgres does not, as on a node taken back to the Alpine image, where
# every run would fail. A setting that cannot be read leaves the timer as it
# is, and the next pass looks again. Failures only warn, since they come after
# the work the caller is there for.
sync_postgres_backups() {
  local mode
  node_takes_backups || return 0
  container_running "$FILONE_POSTGRES_CONTAINER" || return 0
  mode="$(postgres_archive_mode)" || {
    echo "  WARNING: could not read archive_mode; $FILONE_POSTGRES_BACKUP_TIMER left as it is"
    return 0
  }
  if [ "$mode" != on ]; then
    if systemctl is-enabled --quiet "$FILONE_POSTGRES_BACKUP_TIMER" 2>/dev/null; then
      if systemctl disable --now "$FILONE_POSTGRES_BACKUP_TIMER" >/dev/null; then
        echo "  Postgres runs with archive_mode=$mode, so $FILONE_POSTGRES_BACKUP_TIMER is disabled"
      else
        echo "  WARNING: could not disable $FILONE_POSTGRES_BACKUP_TIMER"
      fi
    fi
    return 0
  fi
  if ! systemctl is-enabled --quiet "$FILONE_POSTGRES_BACKUP_TIMER" 2>/dev/null; then
    # The unit may not be on the box yet when this runs by hand, before a
    # reconcile pass has installed the checkout's units.
    sync_systemd_units
    if ! systemctl enable --now "$FILONE_POSTGRES_BACKUP_TIMER" >/dev/null; then
      echo "  WARNING: could not enable $FILONE_POSTGRES_BACKUP_TIMER; the next pass retries"
      return 0
    fi
    echo "  $FILONE_POSTGRES_BACKUP_TIMER enabled"
  fi
  request_postgres_backup
}

# Start a base backup in the background while the running cluster has none:
# WAL is no use for a restore without a base backup of its own cluster to
# replay it onto, so the first one does not wait for the timer. Every reconcile
# pass asks, so a first backup that fails, because WAL-G was not installed yet
# or for any other reason, is retried within a pass rather than a day; one that
# keeps failing shows in the unit's journal. Only where the timer is enabled and
# Postgres archives.
request_postgres_backup() {
  local sysid
  node_takes_backups || return 0
  systemctl is-enabled --quiet "$FILONE_POSTGRES_BACKUP_TIMER" 2>/dev/null || return 0
  container_running "$FILONE_POSTGRES_CONTAINER" || return 0
  sysid="$(postgres_system_identifier)" || return 0
  [ "$(cat "$(postgres_backup_cluster_file)" 2>/dev/null)" != "$sysid" ] || return 0
  [ "$(postgres_archive_mode)" = on ] || return 0
  # A oneshot unit is activating, not active, for as long as it runs.
  case "$(systemctl show -P ActiveState "$FILONE_POSTGRES_BACKUP_SERVICE" 2>/dev/null)" in
    active | activating | deactivating | reloading) return 0 ;;
  esac

  echo "  Postgres has no base backup of this cluster yet; starting one"
  systemctl start --no-block "$FILONE_POSTGRES_BACKUP_SERVICE" ||
    echo "  WARNING: could not start $FILONE_POSTGRES_BACKUP_SERVICE; the next reconcile pass retries"
}

# Stamp a base backup of the cluster with this system identifier that reached
# the backup bucket. The deadman for the base backups, in the shape of the
# OpenBao snapshot stamp.
stamp_postgres_backup_success() {
  local sysid="$1" record tmp
  record="$(postgres_backup_cluster_file)"
  printf '%s\n' "$sysid" >"$record.tmp"
  mv -f "$record.tmp" "$record"
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
#
# The subshell sets errexit itself: run as the left side of || or &&, it would
# run with errexit ignored, and a failed read in it would render an empty field
# over a good config. Every caller runs under set -e, which this puts back.
refresh_walg_config() {
  local status
  set +e
  (
    set -e
    write_walg_config
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || return 0
  echo "  WARNING: could not render WAL-G's config this pass. Postgres archives with the" \
    "one an earlier pass rendered for its cluster, and cannot archive without one." \
    "scripts/host/check-backup-target.sh tests the key."
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
