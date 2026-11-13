#!/usr/bin/env bash
# Tests for check-bind-mounts.sh. Each case feeds it one resolved compose
# project and compares everything it prints, plus the exit status CI reads.
#
# Usage: scripts/ci/test-check-bind-mounts.sh
set -euo pipefail

check="$(dirname "$(readlink -f "$0")")/check-bind-mounts.sh"
failures=0

# Usage: expect <case name> <expected output> <compose json>
expect() {
  local name="$1" want="$2" project="$3" got status
  if [ -z "$want" ]; then status=0; else status=1; fi
  want="${want:+$want
}exit $status"
  got="$("$check" <<<"$project" 2>&1; echo "exit $?")"
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/     /' || true
    failures=$((failures + 1))
  fi
}

guarded='{"type": "bind", "source": "/mnt/any/data", "target": "/data", "bind": {"create_host_path": false}}'
creating='{"type": "bind", "source": "/mnt/any/data", "target": "/data", "bind": {"create_host_path": true}}'

expect "passes a bind that refuses to create its source" "" \
  "{\"services\": {\"any\": {\"volumes\": [$guarded]}}}"

expect "reports a bind that may create its source" \
  "any: bind /mnt/any/data may create its source; set create_host_path: false" \
  "{\"services\": {\"any\": {\"volumes\": [$creating]}}}"

# Short syntax has no bind options at all, which compose resolves to true.
expect "reports a bind with no create_host_path option" \
  "any: bind /mnt/any/data may create its source; set create_host_path: false" \
  '{"services": {"any": {"volumes": [{"type": "bind", "source": "/mnt/any/data", "target": "/data"}]}}}'

expect "reports every offending bind of one service" \
  "any: bind /mnt/any/data may create its source; set create_host_path: false
any: bind /etc/any.conf may create its source; set create_host_path: false" \
  "{\"services\": {\"any\": {\"volumes\": [$creating,
     {\"type\": \"bind\", \"source\": \"/etc/any.conf\", \"target\": \"/c\", \"read_only\": true}]}}}"

expect "reports each offending service" \
  "first: bind /mnt/any/data may create its source; set create_host_path: false
second: bind /mnt/any/data may create its source; set create_host_path: false" \
  "{\"services\": {\"first\": {\"volumes\": [$creating]}, \"second\": {\"volumes\": [$creating]}}}"

expect "passes an exempt service whose bind may create its source" "" \
  "{\"services\": {\"any\": {\"x-filone-bind-check\": \"exempt: any reason\", \"volumes\": [$creating]}}}"

expect "passes a service with no bind mounts" "" \
  '{"services": {"any": {"volumes": [{"type": "volume", "source": "any-volume", "target": "/v"},
     {"type": "tmpfs", "target": "/t"}]}}}'

expect "passes a service with no volumes at all" "" \
  '{"services": {"any": {"image": "any"}}}'

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed" >&2; exit 1; }
