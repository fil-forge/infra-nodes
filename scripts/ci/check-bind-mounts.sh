#!/usr/bin/env bash
# Check that no bind mount in a compose project can create its own source.
#
# Docker's default is to create a missing bind source as an empty directory and
# mount that. On an appliance it is that directory which does the damage: a
# service whose volume is not mounted then starts on an empty directory on the
# root disk instead of refusing to start. Piri writes new blobs there, Postgres
# initialises a new cluster, and a service that expects a file gets a directory.
#
# `create_host_path: false` makes Docker refuse instead, on every start,
# including the starts it makes at boot where no host script runs. The rule here
# is the whole of it: every bind in every service sets it. That covers the
# volume-backed paths, the rendered secrets and the committed config files
# alike, so there is no per-node list to keep in step.
#
# A service that has to start even when a bind source is missing says so with
# `x-filone-bind-check: "exempt: <reason>"` and is skipped.
#
# Usage:
#   docker compose config --no-interpolate --format json |
#     scripts/ci/check-bind-mounts.sh
#
# Prints one line per offending bind and exits 1 if there is any.
set -euo pipefail

[ $# -eq 0 ] || { echo "usage: $0 < compose.json" >&2; exit 2; }

problems="$(jq -r '
  (.services // {}) | to_entries[]
  | .key as $service
  | .value
  | select(has("x-filone-bind-check") | not)
  | (.volumes // [])[]
  | select(.type == "bind")
  | select(.bind.create_host_path != false)
  | "\($service): bind \(.source) may create its source; set create_host_path: false"
')"

[ -z "$problems" ] || { printf '%s\n' "$problems"; exit 1; }
