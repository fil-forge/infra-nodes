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

node_dir() {
  local node="$1"
  [ -d "$REPO_ROOT/nodes/$node" ] || die "no node '$node' under $REPO_ROOT/nodes"
  echo "$REPO_ROOT/nodes/$node"
}

# Values only OpenTofu knows. Reading them from state rather than taking them as
# arguments is what stops a token being bound to the wrong node's address.
tofu_output() {
  local node="$1" name="$2" value
  value="$(tofu -chdir="$REPO_ROOT/terraform/envs/$node" output -raw "$name" 2>/dev/null)" ||
    die "no output '$name' for node '$node'. Has terraform/envs/$node been applied,
       and is tofu initialised in it?"
  echo "$value"
}

# The seal stanza in the node's bao.hcl is the only statement of where central
# is and which key this node uses, so everything reads it from there.
#
# Scoped to that stanza rather than to the file. `address` appears twice in
# bao.hcl — once in the listener block, which comes first — so taking the first
# match in the file would point an operator at the node's own loopback instead
# of at central.
bao_hcl_seal_value() {
  local node="$1" key="$2" value
  value="$(awk -v key="$key" '
    /^seal[[:space:]]+"/ { inside = 1; next }
    inside && /^}/       { inside = 0 }
    inside && $1 == key && match($0, /"[^"]*"/) {
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  ' "$(node_dir "$node")/platform/config/openbao/bao.hcl")"
  [ -n "$value" ] || die "no '$key' in the seal stanza of the node's bao.hcl"
  echo "$value"
}

# Run a command on the node over SSM and return its stdout.
#
# There is no SSH on these boxes and no inbound port for one. Every command sent
# this way is recorded in SSM's command history, so nothing that would be
# damaging in a log goes through here.
ssm_run() {
  local instance_id="$1" script="$2" command_id status

  # JSON rather than the `commands=...` shorthand: the shorthand splits its
  # value on commas, and any script with a comma in it arrives cut into pieces.
  local parameters
  parameters="$(python3 -c \
    'import json,sys; print(json.dumps({"commands": [sys.stdin.read()]}))' <<<"$script")"

  command_id="$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters "$parameters" \
    --query 'Command.CommandId' --output text)"

  aws ssm wait command-executed --command-id "$command_id" --instance-id "$instance_id" 2>/dev/null || true

  status="$(aws ssm get-command-invocation \
    --command-id "$command_id" --instance-id "$instance_id" \
    --query 'Status' --output text)"

  if [ "$status" != "Success" ]; then
    aws ssm get-command-invocation \
      --command-id "$command_id" --instance-id "$instance_id" \
      --query 'StandardErrorContent' --output text >&2
    die "command on $instance_id finished as $status"
  fi

  aws ssm get-command-invocation \
    --command-id "$command_id" --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text
}
