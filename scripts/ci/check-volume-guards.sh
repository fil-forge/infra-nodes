#!/usr/bin/env bash
# Check that no service in a compose project can start on an unmounted volume.
#
# Each volume a node mounts carries a marker file at its root,
# .filone-volume-<name>, written when the volume is prepared. A service that
# binds anything on a volume also binds that volume's marker, read-only and with
# create_host_path: false. When the volume is not mounted the marker is missing,
# and Docker refuses to start the container, including when it restarts it at
# boot, where none of the host scripts run.
#
# The rules, for every bind whose source is on a volume:
#   - the service also binds that volume's marker, read-only;
#   - neither bind may create its source, or Docker would make the path on the
#     root disk and bind that instead.
# A service marked `x-filone-volume-guard: exempt: <reason>` is skipped.
#
# Usage:
#   docker compose config --no-interpolate --format json |
#     scripts/ci/check-volume-guards.sh "<name>:<path> ..."
#
# The volumes are FILONE_VOLUMES from the node's node.env. Prints one line per
# problem and exits 1 if there is any.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 '<name>:<path> ...' < compose.json" >&2; exit 2; }

problems="$(jq -r --arg volumes "$1" '
  ($volumes | split(" ") | map(select(. != "") | split(":") | {name: .[0], path: .[1]})) as $volumes
  | def marker($volume): "\($volume.path)/.filone-volume-\($volume.name)";
    def on($volume): . == $volume.path or startswith($volume.path + "/");
    (.services // {}) | to_entries[]
  | .key as $service
  | .value
  | select(has("x-filone-volume-guard") | not)
  | [.volumes // [] | .[] | select(.type == "bind")] as $binds
  | ($binds | map(.source)) as $sources
  | $binds[]
  | . as $bind
  | $volumes[]
  | . as $volume
  | select($bind.source | on($volume))
  | (if $bind.bind.create_host_path == false then empty
     else "\($service): bind \($bind.source) may create its source on the root disk; set create_host_path: false"
     end),
    (if $bind.source == marker($volume) then
       (if $bind.read_only == true then empty
        else "\($service): marker \($bind.source) must be read_only" end)
     elif ($sources | index(marker($volume))) then empty
     else "\($service): binds \($bind.source) on volume \($volume.name) without the marker \(marker($volume))"
     end)
')"

[ -z "$problems" ] || { printf '%s\n' "$problems"; exit 1; }
