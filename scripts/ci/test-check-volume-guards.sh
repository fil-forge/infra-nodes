#!/usr/bin/env bash
# Tests for check-volume-guards.sh. Each case feeds it one resolved compose
# project and compares everything it prints, so a failure shows the whole
# report rather than a yes or no.
#
# Usage: scripts/ci/test-check-volume-guards.sh
set -euo pipefail

check="$(dirname "$(readlink -f "$0")")/check-volume-guards.sh"
volumes="control:/mnt/any/control piri-0:/mnt/any/piri-0"
failures=0

# Usage: expect <case name> <expected output> <compose json>
#
# The exit status is compared too, since that is what fails CI: 0 when nothing
# is expected, 1 otherwise.
expect() {
  local name="$1" want="$2" project="$3" got status
  if [ -z "$want" ]; then status=0; else status=1; fi
  want="${want:+$want
}exit $status"
  got="$("$check" "$volumes" <<<"$project" 2>&1; echo "exit $?")"
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/     /' || true
    failures=$((failures + 1))
  fi
}

marker='{"type": "bind", "source": "/mnt/any/piri-0/.filone-volume-piri-0", "target": "/run/filone-volume/piri-0",
         "read_only": true, "bind": {"create_host_path": false}}'
data='{"type": "bind", "source": "/mnt/any/piri-0", "target": "/data", "bind": {"create_host_path": false}}'

expect "passes a service that binds its volume's marker" "" \
  "{\"services\": {\"any\": {\"volumes\": [$marker, $data]}}}"

expect "reports a service that binds a volume without its marker" \
  "any: binds /mnt/any/piri-0 on volume piri-0 without the marker /mnt/any/piri-0/.filone-volume-piri-0" \
  "{\"services\": {\"any\": {\"volumes\": [$data]}}}"

# Under the volume, so the subdirectory is on it too.
expect "reports a subdirectory of a volume bound without its marker" \
  "any: binds /mnt/any/control/postgres on volume control without the marker /mnt/any/control/.filone-volume-control" \
  '{"services": {"any": {"volumes": [
     {"type": "bind", "source": "/mnt/any/control/postgres", "target": "/data", "bind": {"create_host_path": false}}]}}}'

# create_host_path true lets Docker make the directory on the root disk.
expect "reports a volume bind that may create its source" \
  "any: bind /mnt/any/piri-0 may create its source on the root disk; set create_host_path: false" \
  "{\"services\": {\"any\": {\"volumes\": [$marker,
     {\"type\": \"bind\", \"source\": \"/mnt/any/piri-0\", \"target\": \"/data\", \"bind\": {\"create_host_path\": true}}]}}}"

# Writable, so the service could delete the marker it is guarded by.
expect "reports a writable marker" \
  "any: marker /mnt/any/piri-0/.filone-volume-piri-0 must be read_only" \
  "{\"services\": {\"any\": {\"volumes\": [$data,
     {\"type\": \"bind\", \"source\": \"/mnt/any/piri-0/.filone-volume-piri-0\", \"target\": \"/run/filone-volume/piri-0\",
      \"bind\": {\"create_host_path\": false}}]}}}"

# create_host_path true would create the marker, as a directory, when the
# volume is missing, which is the one thing it must never do.
expect "reports a marker that may be created" \
  "any: bind /mnt/any/piri-0/.filone-volume-piri-0 may create its source on the root disk; set create_host_path: false" \
  "{\"services\": {\"any\": {\"volumes\": [$data,
     {\"type\": \"bind\", \"source\": \"/mnt/any/piri-0/.filone-volume-piri-0\", \"target\": \"/run/filone-volume/piri-0\",
      \"read_only\": true, \"bind\": {\"create_host_path\": true}}]}}}"

expect "passes an exempt service that binds a volume unguarded" "" \
  '{"services": {"any": {"x-filone-volume-guard": "exempt: any reason",
     "volumes": [{"type": "bind", "source": "/mnt/any/control/any", "target": "/data", "bind": {"create_host_path": true}}]}}}'

# Shares a prefix with the control volume's path but is not under it.
expect "passes a bind outside every volume" "" \
  '{"services": {"any": {"volumes": [
     {"type": "bind", "source": "/mnt/any/control-elsewhere", "target": "/data", "bind": {"create_host_path": true}},
     {"type": "volume", "source": "any-volume", "target": "/other"}]}}}'

expect "reports each offending service" \
  "first: binds /mnt/any/piri-0 on volume piri-0 without the marker /mnt/any/piri-0/.filone-volume-piri-0
second: binds /mnt/any/piri-0 on volume piri-0 without the marker /mnt/any/piri-0/.filone-volume-piri-0" \
  "{\"services\": {\"first\": {\"volumes\": [$data]}, \"second\": {\"volumes\": [$data]}}}"

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed" >&2; exit 1; }
