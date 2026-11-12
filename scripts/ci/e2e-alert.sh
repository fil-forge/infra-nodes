#!/usr/bin/env bash
# Write the filone-alerts message for a failed end-to-end test: what failed, what
# started the run, and where to look first.
#
# Usage:
#   scripts/ci/e2e-alert.sh
#
# Everything comes from the environment, as e2e.yml passes it:
#
#   NODE              the node tested
#   TRIGGER           change (a deploy dispatched the run), schedule or manual
#   E2E_OUTCOME       the test step's outcome
#   E2E_FAILED_OP     the operation that failed, from e2e-test.sh
#   CLEANUP_OUTCOME   the cleanup step's outcome
#   LEFTOVER_TENANT   what cleanup left behind, from e2e-test.sh
#   LEFTOVER_BUCKET
#   RUNBOOK           the runbook section on cleaning up by hand
#   ACTOR             who started the run (manual)
#   CHANGE_REPO       the deployed change (change): infra-nodes or
#   CHANGE_SHA        infra-central, its full sha, its subject and the
#   CHANGE_SUBJECT    login that pushed it
#   CHANGE_AUTHOR
#
# Writes headline, cause and next, each one line of Slack mrkdwn, to
# $GITHUB_OUTPUT, or prints them outside GitHub Actions. cause is empty for a
# scheduled run.
set -euo pipefail

main() {
  local headline cause next

  if [ "$E2E_OUTCOME" = failure ]; then
    headline="The $NODE node failed its end-to-end test: $(slack_escape "${E2E_FAILED_OP:-see the run log}")"
    case "$TRIGGER:${CHANGE_REPO-}" in
      change:infra-nodes) next="The node answers its health checks but cannot serve a customer. Suspect the image this commit pinned, or Hilt." ;;
      change:infra-central) next="Suspect the central change first, then the node's own state: every central deploy starts this test, whatever it changed." ;;
      *) next="Nothing was deployed for this run. Suspect drift on the node or in central, such as a rotated partner key." ;;
    esac
  elif [ "$CLEANUP_OUTCOME" = failure ]; then
    headline="The $NODE node passed its end-to-end test, but the cleanup failed"
    next="The node serves customers; the test could not delete what it created."
  else
    headline="The end-to-end test of the $NODE node did not run"
    next="A step before the test failed. The run log has the error."
  fi
  if [ "$CLEANUP_OUTCOME" = failure ]; then
    next="$next Left behind: tenant ${LEFTOVER_TENANT:-none}, bucket ${LEFTOVER_BUCKET:-none}. Delete them by hand: <$RUNBOOK|runbook>."
  fi

  case "$TRIGGER" in
    change)
      case "$CHANGE_REPO" in
        infra-nodes | infra-central) ;;
        *) echo "unknown CHANGE_REPO: $CHANGE_REPO" >&2; exit 2 ;;
      esac
      cause="Triggered by $CHANGE_REPO change: \`$(first_line "$CHANGE_SUBJECT")\` by $(github_user "$CHANGE_AUTHOR") (<https://github.com/fil-forge/$CHANGE_REPO/commit/$CHANGE_SHA|$CHANGE_REPO@${CHANGE_SHA:0:7}>)"
      ;;
    manual) cause="Started by hand by $(github_user "$ACTOR")" ;;
    schedule) cause="" ;;
    *) echo "unknown TRIGGER: $TRIGGER" >&2; exit 2 ;;
  esac

  output headline "$headline"
  output cause "$cause"
  output next "$next"
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

# output — one line, because GITHUB_OUTPUT reads a newline as the end of the
# value, and a failed operation can quote a multi-line response.
output() {
  local value
  value=$(printf '%s' "$2" | tr '\n' ' ')
  if [ -n "${GITHUB_OUTPUT-}" ]; then
    printf '%s=%s\n' "$1" "$value" >>"$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$value"
  fi
}

main
