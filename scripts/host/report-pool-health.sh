#!/usr/bin/env bash
# Report the node's ZFS pools' scrub results and error counts to Alloy's
# textfile collector.
#
# The pool's state (online, degraded, faulted and so on) does not come from
# here: Alloy's zfs collector reads it from the kernel on every scrape, as
# node_zfs_zpool_state. What the kernel does not publish is what the last scrub
# found and the error counters `zpool status` prints, so this reads them from
# `zpool status -j --json-int` (OpenZFS 2.3 or later) and writes zfs_pool.prom:
#
#   zfs_pool_scan_errors{zpool, function}         errors the latest scrub or
#                                                 resilver could not repair
#   zfs_pool_scan_end_timestamp{zpool, function}  when it ended; 0 while it runs
#   zfs_pool_data_errors{zpool}                   files with permanent errors
#   zfs_pool_vdev_errors{zpool, vdev, type}       read, write and checksum
#                                                 errors per vdev since the
#                                                 pool was imported (at boot)
#                                                 or last cleared
#
# A pool that has never been scrubbed or resilvered has no scan series.
#
# Runs from filone-pool-health.timer every five minutes on a node whose state
# is on ZFS; the runbook enables the timer there. Run it by hand, as root, to
# report now. It reads the pool and changes nothing but its own file, so it
# takes no lock. When zpool fails, the last report stays in place and the run
# fails: node_textfile_mtime_seconds for the file then stops moving, which is
# what central's not-reporting alert reads.
#
# Usage:
#   scripts/host/report-pool-health.sh
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

status="$(zpool status -j --json-int)" || die "zpool status failed; see its error above"

# Written aside and moved, as deploy.prom is, so a scrape never reads half a
# file. Every family is declared once, here, and in no other file.
tmp="$(mktemp "$FILONE_METRICS_DIR/.zfs-pool.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

jq -r '
  def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
  def family($name; $help): "# HELP \($name) \($help)", "# TYPE \($name) gauge";
  [.pools // {} | to_entries[] | .key as $pool | .value | {pool: $pool, item: .}] as $pools
  | ($pools | map(select(.item.scan_stats.function // "NONE" | IN("SCRUB", "RESILVER")))) as $scanned
  | family("zfs_pool_scan_errors"; "Errors the latest scrub or resilver of the pool could not repair."),
    ($scanned[] | "zfs_pool_scan_errors{zpool=\"\(.pool | esc)\",function=\"\(.item.scan_stats.function | ascii_downcase)\"} \(.item.scan_stats.errors)"),
    family("zfs_pool_scan_end_timestamp"; "Unix time the latest scrub or resilver of the pool ended, 0 while it runs."),
    ($scanned[] | "zfs_pool_scan_end_timestamp{zpool=\"\(.pool | esc)\",function=\"\(.item.scan_stats.function | ascii_downcase)\"} \(.item.scan_stats.end_time)"),
    family("zfs_pool_data_errors"; "Files in the pool with permanent errors."),
    ($pools[] | select(.item.error_count != null) | "zfs_pool_data_errors{zpool=\"\(.pool | esc)\"} \(.item.error_count)"),
    family("zfs_pool_vdev_errors"; "Read, write and checksum errors on a vdev of the pool since it was imported or last cleared."),
    ($pools[] | .pool as $pool | .item.vdevs // {} | .. | objects | select(has("checksum_errors"))
      | . as $vdev | ("read", "write", "checksum")
      | "zfs_pool_vdev_errors{zpool=\"\($pool | esc)\",vdev=\"\($vdev.name | esc)\",type=\"\(.)\"} \($vdev[. + "_errors"])")
' <<<"$status" >"$tmp" || die "could not read zpool status output as JSON"

chmod 0644 "$tmp"
mv "$tmp" "$FILONE_METRICS_DIR/zfs_pool.prom"
