#!/usr/bin/env bash
# Shared helpers for the scripts an operator runs from their own machine.
#
# Sourced, never executed. These need AWS credentials for the account the node
# runs in; the node itself has none of that.

# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null || die "$1 is not installed"
}

# Values only OpenTofu knows. Read from state rather than taken as an argument,
# so a session cannot be opened against an instance id typed from memory.
tofu_output() {
  local node="$1" name="$2" value errors
  local errors_file="${TMPDIR:-/tmp}/tofu-output.$$"

  # OpenTofu's own message says whether this is a missing output, an
  # uninitialised directory, or expired credentials. Swallowing it turns three
  # different problems into one unhelpful line.
  value="$(tofu -chdir="$REPO_ROOT/terraform/envs/$node" output -raw "$name" 2>"$errors_file")" || {
    errors="$(sed 's/^/  /' "$errors_file")"
    rm -f "$errors_file"
    die "no output '$name' for node '$node'. Has terraform/envs/$node been applied,
and is tofu initialised in it? OpenTofu said:

$errors"
  }
  rm -f "$errors_file"
  echo "$value"
}
