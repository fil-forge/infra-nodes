#!/bin/sh
# Postgres's archive_command on a node that takes backups: push one WAL segment
# to the backup bucket with WAL-G, under the config rendered for this cluster.
#
# Usage: filone-wal-push <WAL-G version> <segment path>
#
# scripts/host/lib/walg.sh renders each cluster's config as
# /etc/wal-g/<system identifier>.json, its prefix named for the same
# identifier. Choosing the file by the identifier this cluster reports, for
# every segment, means no config rendered for another cluster is ever used. A
# cluster initialised again, before a pass has rendered its own, finds none:
# the push fails, Postgres keeps the segment and retries, and the archive alert
# watches. Otherwise its first segments, archived even during initdb, would go
# up under the earlier cluster's prefix, in front of that cluster's archive.
set -eu

version="$1"
segment="$2"

# Postgres runs archive_command in the data directory. LC_ALL=C keeps the
# label the sed matches in English.
sysid="$(LC_ALL=C pg_controldata -D . | sed -n 's/^Database system identifier: *//p')"
if [ -z "$sysid" ]; then
  echo "filone-wal-push: could not read this cluster's system identifier" >&2
  exit 1
fi
config="/etc/wal-g/$sysid.json"
if [ ! -r "$config" ]; then
  echo "filone-wal-push: no WAL-G config for cluster $sysid at $config yet" >&2
  exit 1
fi
exec "/opt/wal-g/$version/wal-g" --config "$config" wal-push "$segment"
