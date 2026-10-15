#!/usr/bin/env bash
# Check that a node's public services answer and that it is running the images
# the checkout pins.
#
# Everything is checked over public HTTPS, which covers the whole ingress route
# at once: the DNS record, the certificate Caddy obtained, Caddy itself, and a
# container passing its health check.
#
# The digest comparison is the one health cannot make. A merged bump is queued
# rather than applied, so a node can be healthy on the image it was running an
# hour ago. Comparing what the containers report against what the pins say at
# the revision the node says it deployed is what proves the bump took.
#
# Usage:
#   scripts/ci/smoke-test.sh <node> [--revision <sha>]
#
# Example:
#   scripts/ci/smoke-test.sh dev
#   scripts/ci/smoke-test.sh dev --revision "$(git rev-parse HEAD)"
#
# --revision also requires the node to have reached that commit or a descendant
# of it, which is what a run after a merge checks. The node stamps a commit on
# every reconcile pass, so this holds for a merge that deployed nothing too.
# Without the flag the node is checked as it stands.
#
# The hostnames come from nodes/<node>/node.env, so they are the ones Caddy
# holds certificates for. The Piris are the services nodes/<node>/apps/compose.yml
# defines; each answers at piri-<n>.$PIRI_HOSTNAME_SUFFIX, or a node with a single
# `piri` at $PIRI_HOSTNAME.
#
# Prerequisites:
#   - curl, jq, and a git work tree deep enough to hold the revisions compared
#   - no credentials, and nothing is written outside a temporary directory
set -euo pipefail

case "${1-}" in
  -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")        echo "usage: scripts/ci/smoke-test.sh <node> [--revision <sha>]" >&2; exit 2 ;;
  -*)        echo "unknown option: $1" >&2; exit 2 ;;
esac

NODE="$1"
shift
REVISION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --revision)
      REVISION="${2-}"
      [ -n "$REVISION" ] || { echo "ERROR: --revision needs a value" >&2; exit 2; }
      shift 2
      ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null || { echo "ERROR: curl not found in PATH" >&2; exit 1; }
command -v jq   >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

NODE_ENV="nodes/$NODE/node.env"
PINS="nodes/$NODE/apps/versions.env"
COMPOSE="nodes/$NODE/apps/compose.yml"
[ -f "$NODE_ENV" ] || { echo "ERROR: no such node '$NODE': $NODE_ENV does not exist" >&2; exit 1; }

read_env() { sed -nE "s/^$1=(.*)\$/\1/p" "$NODE_ENV" | tail -1; }
PIRI_HOSTNAME_SUFFIX="$(read_env PIRI_HOSTNAME_SUFFIX)"
PIRI_HOSTNAME="$(read_env PIRI_HOSTNAME)"
INGOT_HOSTNAME="$(read_env INGOT_HOSTNAME)"
[ -n "$INGOT_HOSTNAME" ] || { echo "ERROR: no INGOT_HOSTNAME in $NODE_ENV" >&2; exit 1; }

# The Piri services in a compose file read on stdin, in index order. The
# services are the two-space-indented keys under `services:`.
piri_services_in() { sed -nE 's/^  (piri(-[0-9]+)?):[[:space:]]*$/\1/p' | sort -V; }

# shellcheck disable=SC2207 # one service name per word
PIRIS=($(piri_services_in <"$COMPOSE"))
[ "${#PIRIS[@]}" -gt 0 ] || { echo "ERROR: $COMPOSE defines no Piri service" >&2; exit 1; }

piri_hostname() {
  if [ -n "$PIRI_HOSTNAME_SUFFIX" ]; then
    echo "$1.$PIRI_HOSTNAME_SUFFIX"
  elif [ "$1" = piri ] && [ -n "$PIRI_HOSTNAME" ]; then
    echo "$PIRI_HOSTNAME"
  else
    echo "ERROR: $NODE_ENV has no PIRI_HOSTNAME_SUFFIX to name $1 by" >&2
    exit 1
  fi
}
for service in "${PIRIS[@]}"; do piri_hostname "$service" >/dev/null; done

# Every Piri hostname serves the document; the full check reads it from the
# first.
STATUS_URL="https://$(piri_hostname "${PIRIS[0]}")/.well-known/filone-node-status.json"

# Every request is bounded. A hung smoke test is worse than a failing one.
#
# No --show-error: curl's own diagnostic would land in the middle of the
# results, and every failure below already names the URL and the reason.
CURL=(curl --silent --max-time 10)

PASS='  ✓'
FAIL='  ✗'

pass() { printf '%s %s\n' "$PASS" "$1"; }
fail() { printf '%s %s\n' "$FAIL" "$1"; }

# check_piri <service> — 200 with .status == "ok", the same condition Piri's own
# container health check uses, now asked over the public path. And the status
# document is served on that hostname too.
check_piri() {
  local host url body status
  host="$(piri_hostname "$1")"
  url="https://$host/readyz"
  if ! body="$("${CURL[@]}" --fail "$url" 2>/dev/null)"; then
    fail "$url — not served (DNS, TLS, HTTP error or timeout)"
  else
    status="$(jq -r '.status // empty' <<<"$body" 2>/dev/null || true)"
    if [ "$status" = ok ]; then
      pass "$url — status ok"
    else
      fail "$url — reports status '${status:-none}', expected ok"
    fi
  fi

  url="https://$host/.well-known/filone-node-status.json"
  if "${CURL[@]}" --fail --output /dev/null "$url" 2>/dev/null; then
    pass "$url — served"
  else
    fail "$url — not served"
  fi
}

check_ingot() {
  local url="https://$INGOT_HOSTNAME/health" code
  # curl writes 000 itself when it never saw a status line, and exits non-zero
  # while doing it, so the status is read from the output rather than the code.
  code="$("${CURL[@]}" --output /dev/null --write-out '%{http_code}' "$url" 2>/dev/null || true)"
  case "$code" in
    200)    pass "$url — HTTP 200" ;;
    000|"") fail "$url — no response (DNS, TLS or timeout)" ;;
    *)      fail "$url — HTTP $code" ;;
  esac
}

# The digest a commit pins a service at. The pin carries a tag as well, and only
# the digest is compared: `docker inspect` reports a repository digest with no
# tag on it, so the two strings never match whole.
pin_at() {
  local revision="$1" key="$2"
  git show "$revision:$PINS" 2>/dev/null |
    sed -nE "s|^${key}=[^@]+@(sha256:[0-9a-f]{64})[[:blank:]]*\$|\1|p"
}

# check_status — the document is served, the node has reached the requested
# commit, and the digests it reports match the pins at the revision it deployed
# apps from.
#
# Two revisions, because they answer two questions. `reconcile` is stamped on
# every pass and is the commit the node has reached, including a commit that
# deployed nothing. `apps` moves only when the apps project deploys, and it is
# the revision the running digests have to be compared against.
check_status() {
  local body reached deployed service key want got deployed_piris

  if ! body="$("${CURL[@]}" --fail "$STATUS_URL" 2>/dev/null)"; then
    fail "$STATUS_URL — not served"
    return
  fi

  reached="$(jq -r '.projects.reconcile.revision // empty' <<<"$body" 2>/dev/null || true)"
  deployed="$(jq -r '.projects.apps.revision // empty' <<<"$body" 2>/dev/null || true)"
  if [ -z "$reached" ] || [ -z "$deployed" ]; then
    fail "$STATUS_URL — reports no revision for reconcile or for apps"
    return
  fi
  pass "$STATUS_URL — reached ${reached:0:7}, apps deployed from ${deployed:0:7}"

  if [ -n "$REVISION" ]; then
    if ! git cat-file -e "$REVISION^{commit}" 2>/dev/null; then
      fail "revision — $REVISION is not in this checkout; fetch more history"
    elif ! git cat-file -e "$reached^{commit}" 2>/dev/null; then
      fail "revision — the node reports $reached, which is not in this checkout"
    elif git merge-base --is-ancestor "$REVISION" "$reached"; then
      pass "revision — ${reached:0:7} is ${REVISION:0:7} or a descendant"
    else
      fail "revision — the node is on ${reached:0:7}, which is not a descendant of ${REVISION:0:7}"
    fi
  fi

  # A missing revision or a missing pins file has to be reported, not skipped.
  # `pin_at` runs under `set -e`, so a failing `git show` would kill this job
  # before it printed either digest line and the run would end up passing.
  if ! git cat-file -e "$deployed^{commit}" 2>/dev/null; then
    fail "apps — the node deployed from $deployed, which is not in this checkout; fetch more history"
    return
  fi
  if ! git cat-file -e "$deployed:$PINS" 2>/dev/null; then
    fail "apps — $PINS does not exist at ${deployed:0:7}"
    return
  fi

  # Against the pins at the revision apps was deployed from, not the working
  # tree. A merge that changed neither compose project leaves apps where it was,
  # so the working tree is routinely ahead of it and comparing against that would
  # fail every honest node. The Piris to compare are the ones compose.yml defined
  # at that revision too, and all of them run the one PIRI_IMAGE pin.
  deployed_piris="$(git show "$deployed:$COMPOSE" 2>/dev/null | piri_services_in || true)"
  if [ -z "$deployed_piris" ]; then
    fail "apps — $COMPOSE at ${deployed:0:7} defines no Piri service"
    return
  fi
  for service in $deployed_piris ingot; do
    case "$service" in
      piri*) key=PIRI_IMAGE ;;
      *) key="$(tr '[:lower:]' '[:upper:]' <<<"$service")_IMAGE" ;;
    esac
    want="$(pin_at "$deployed" "$key")"
    got="$(jq -r --arg service "$service" '.images[$service] // empty' <<<"$body" 2>/dev/null || true)"
    got="${got##*@}"

    if [ -z "$want" ]; then
      fail "$service — $PINS at ${deployed:0:7} pins no digest through $key"
    elif [ -z "$got" ]; then
      fail "$service — the node reports no running digest"
    elif [ "$want" = "$got" ]; then
      pass "$service — running ${got:0:14}, as pinned at ${deployed:0:7}"
    else
      fail "$service — running ${got:0:14}, but ${deployed:0:7} pins ${want:0:14}"
    fi
  done
}

echo "=== Smoke-test the $NODE node ==="
for service in "${PIRIS[@]}"; do
  echo "  $service: https://$(piri_hostname "$service")"
done
echo "  ingot: https://$INGOT_HOSTNAME"
[ -z "$REVISION" ] || echo "  Waiting on revision ${REVISION:0:7} or a descendant"
echo

# One job per check. A hostname that does not resolve answers at once, but one
# that accepts the connection and never replies waits out the full --max-time,
# and three of those in sequence is half a minute of nothing. Each job writes to
# its own file and the results are printed in table order afterwards, so a
# parallel run reads exactly like a sequential one.
#
# Each entry is <result file>:<label>:<check function> [argument].
CHECKS=()
for service in "${PIRIS[@]}"; do
  CHECKS+=("$service:Piri ($service):check_piri $service")
done
CHECKS+=("ingot:Ingot:check_ingot" "status:Node status:check_status")

results="$(mktemp -d "${TMPDIR:-/tmp}/filone-smoke.XXXXXX")"
trap 'rm -rf "$results"' EXIT

pids=()
for entry in "${CHECKS[@]}"; do
  # shellcheck disable=SC2086 # the function name and its argument
  ${entry##*:} >"$results/${entry%%:*}" 2>&1 &
  pids+=("$!")
done

# Each job is waited on by pid. A bare `wait` reports success however the jobs
# ended, so a check that died halfway would leave a short results file and the
# run would report OK on the checks that never happened.
for i in "${!CHECKS[@]}"; do
  entry="${CHECKS[$i]}"
  wait "${pids[$i]}" ||
    fail "the check exited before it finished" >>"$results/${entry%%:*}"
done

for entry in "${CHECKS[@]}"; do
  label="${entry#*:}"
  echo "${label%%:*}"
  cat "$results/${entry%%:*}"
  echo
done

failures="$(cat "$results"/* | grep -c "^${FAIL} " || true)"

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures check(s)"
  exit 1
fi

echo "OK: every check passed"
