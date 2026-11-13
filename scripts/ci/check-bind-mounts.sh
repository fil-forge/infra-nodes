#!/usr/bin/env bash
# Fail on a bind mount of appliance data that Docker would create when missing.
#
# Usage:
#   docker compose ... config --format json | scripts/ci/check-bind-mounts.sh
#
# Data lives under /mnt (the control, data and Piri volumes) and /var/lib/fil-one.
# Each bind from there needs create_host_path: false, so that when the volume
# did not mount, Docker refuses to start the container, at boot included,
# instead of creating an empty directory on the root disk and running on it.
set -euo pipefail

bad="$(jq -r '
  .services | to_entries[] | .key as $service
  | .value.volumes // [] | .[]
  | select(.type == "bind")
  | select(.source | startswith("/mnt/") or startswith("/var/lib/fil-one/"))
  | select(.bind.create_host_path != false)
  | "\($service): \(.source)"
')"

[ -z "$bad" ] && exit 0
while read -r line; do
  echo "  $line needs the long syntax with bind: create_host_path: false" >&2
done <<<"$bad"
exit 1
