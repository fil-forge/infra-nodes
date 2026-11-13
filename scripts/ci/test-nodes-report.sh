#!/usr/bin/env bash
# Write the one filone-alerts message for a Test nodes run: which nodes failed
# and how, what they left behind, what started the run, and where to look
# first.
#
# Usage:
#   scripts/ci/test-nodes-report.sh <results dir> <payload file>
#
# <results dir> holds the JSON each node's job wrote with test-nodes-result.sh.
# It may be empty or missing: a node whose job died before writing its result
# is reported as having ended without one.
#
# Everything else comes from the environment, as test-nodes.yml passes it:
#
#   MATRIX            the select job's matrix, naming every node the run tested
#   TRIGGER           change (a push or a deploy started the run), schedule or
#                     manual
#   ACTOR             who started the run (manual)
#   CHANGE_REPO       the change (change): infra-nodes or infra-central, its
#   CHANGE_SHA        full sha, its subject and the login that pushed it
#   CHANGE_SUBJECT
#   CHANGE_AUTHOR
#   SERVICE_LINE      for an image bump, the service commit behind the image,
#                     already Slack mrkdwn; may be empty
#   RUN_URL           the run
#   RUNBOOK           the runbook section on cleaning up by hand
#
# Writes a chat.postMessage payload for slackapi/slack-github-action to
# <payload file>. Exits 1, writing nothing, when every node passed.
set -euo pipefail

main() {
  local results_dir="${1-}" payload_file="${2-}"
  [ -n "$results_dir" ] && [ -n "$payload_file" ] ||
    { echo "usage: scripts/ci/test-nodes-report.sh <results dir> <payload file>" >&2; exit 2; }

  local results='[]'
  if [ -d "$results_dir" ] && compgen -G "$results_dir/*.json" >/dev/null; then
    results=$(jq -s . "$results_dir"/*.json)
  fi

  # Every node the run tested, with its result, or null for a node whose job
  # never wrote one.
  local nodes
  nodes=$(jq -c --argjson results "$results" '
    [.include[].node as $node | {node: $node, result: ([$results[] | select(.node == $node)] | first)}]
  ' <<<"$MATRIX")

  local failed_nodes
  failed_nodes=$(jq -r '[.[] | select(.result == null or .result.failed_step != "") | .node] | join(", ")' <<<"$nodes")
  if [ -z "$failed_nodes" ]; then
    echo "every node passed; nothing to report" >&2
    exit 1
  fi

  local headline="Node test failed on $failed_nodes"
  local -a lines=()
  local node_json
  while IFS= read -r node_json; do
    lines+=("$(describe_node "$node_json")")
  done < <(jq -c '.[] | select(.result == null or .result.failed_step != "")' <<<"$nodes")

  local cause
  cause=$(describe_trigger)
  [ -z "$cause" ] || lines+=("$cause")
  [ -z "${SERVICE_LINE-}" ] || lines+=("$SERVICE_LINE")

  local body
  body=$(printf '%s\n' "${lines[@]}")
  jq -n \
    --arg headline "$(slack_escape "$headline")" \
    --arg body "$body" \
    --arg run_url "$RUN_URL" \
    '{
      channel: "filone-alerts",
      text: "\($headline). Details: \($run_url)",
      blocks: [
        {type: "section", text: {type: "mrkdwn", text: ":warning: *\($headline)* · <\($run_url)|Details>"}},
        {type: "section", text: {type: "mrkdwn", text: $body}}
      ]
    }' >"$payload_file"
  cat "$payload_file"
}

# describe_node — one line: the node, what failed, and where to look first.
describe_node() {
  local node_json="$1" node step outcome failed_op line
  node=$(slack_escape "$(jq -r .node <<<"$node_json")")
  if [ "$(jq -r '.result == null' <<<"$node_json")" = true ]; then
    echo "• *$node* ended without reporting a result. The run log says where its job stopped."
    return
  fi
  step=$(jq -r .result.failed_step <<<"$node_json")
  outcome=$(jq -r .result.outcome <<<"$node_json")
  failed_op=$(slack_escape "$(jq -r '.result.failed_op | select(. != "") // "see the run log"' <<<"$node_json")")

  if [ "$outcome" = cancelled ]; then
    line="• *$node* hit its time limit during the $(step_name "$step"). The run log says where it stopped."
  else
    case "$step" in
      wait) line="• *$node* never reached \`${CHANGE_SHA:0:7}\` within 60 minutes. Check reconcile on the node: the proving gate, a failing deploy, or a node tracking another ref." ;;
      smoke) line="• *$node* failed its smoke test. $(smoke_hint)" ;;
      e2e) line="• *$node* failed its end-to-end test: $failed_op. $(e2e_hint)" ;;
      cleanup) line="• *$node* passed its end-to-end test, but the cleanup failed. The node serves customers; the test could not delete what it created." ;;
      setup) line="• *$node* failed before its tests started. The run log has the error." ;;
      *) echo "unknown failed_step for $node: '$step'" >&2; exit 2 ;;
    esac
  fi

  if [ "$(jq -r .result.cleanup_outcome <<<"$node_json")" = failure ]; then
    local tenant bucket
    tenant=$(slack_escape "$(jq -r '.result.leftover_tenant | select(. != "") // "none"' <<<"$node_json")")
    bucket=$(slack_escape "$(jq -r '.result.leftover_bucket | select(. != "") // "none"' <<<"$node_json")")
    line="$line Left behind: tenant $tenant, bucket $bucket. Delete them by hand: <$RUNBOOK|runbook>."
  fi
  echo "$line"
}

step_name() {
  case "$1" in
    wait) echo "wait for the commit" ;;
    smoke) echo "smoke test" ;;
    e2e) echo "end-to-end test" ;;
    cleanup) echo "cleanup" ;;
    *) echo "setup" ;;
  esac
}

smoke_hint() {
  case "$TRIGGER:${CHANGE_REPO-}" in
    change:infra-nodes) echo "The node has this commit and is not serving it. Suspect the image it pinned." ;;
    *) echo "Nothing in infra-nodes was deployed for this run, so check the node's services." ;;
  esac
}

e2e_hint() {
  case "$TRIGGER:${CHANGE_REPO-}" in
    change:infra-nodes) echo "The node answers its health checks but cannot serve a customer. Suspect the image this commit pinned, or Hilt." ;;
    change:infra-central) echo "Suspect the central change first, then the node's own state: every central deploy starts this test, whatever it changed." ;;
    *) echo "Nothing was deployed for this run. Suspect drift on the node or in central, such as a rotated partner key." ;;
  esac
}

# describe_trigger — what started the run; nothing for the hourly schedule.
describe_trigger() {
  case "$TRIGGER" in
    change)
      case "$CHANGE_REPO" in
        infra-nodes | infra-central) ;;
        *) echo "unknown CHANGE_REPO: $CHANGE_REPO" >&2; exit 2 ;;
      esac
      echo "Triggered by $CHANGE_REPO change: \`$(first_line "$CHANGE_SUBJECT")\` by $(github_user "$CHANGE_AUTHOR") (<https://github.com/fil-forge/$CHANGE_REPO/commit/$CHANGE_SHA|$CHANGE_REPO@${CHANGE_SHA:0:7}>)"
      ;;
    manual) echo "Started by hand by $(github_user "$ACTOR")" ;;
    schedule) ;;
    *) echo "unknown TRIGGER: $TRIGGER" >&2; exit 2 ;;
  esac
}

# first_line — the first line, escaped for Slack. A commit subject is free to
# contain anything.
first_line() {
  slack_escape "${1%%$'\n'*}"
}

# github_user — a login as a link. An App acting as itself, such as
# fil-forge-bot[bot], has its page under /apps.
github_user() {
  local login
  login=$(slack_escape "$1")
  case "$login" in
    *'[bot]') echo "<https://github.com/apps/${login%'[bot]'}|@$login>" ;;
    *) echo "<https://github.com/$login|@$login>" ;;
  esac
}

# slack_escape — the three characters Slack's mrkdwn reads as markup.
slack_escape() {
  local text="$1"
  # Quoted, because bash 5.2 reads an unquoted & in the replacement as the
  # matched text.
  text=${text//'&'/'&amp;'}
  text=${text//'<'/'&lt;'}
  text=${text//'>'/'&gt;'}
  printf '%s' "$text"
}

main "$@"
