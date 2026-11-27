#!/usr/bin/env bash
# Print the title of an image bump pull request. The title becomes the subject
# of the squash commit on main, so it carries the subject of the service commit
# the image was built from:
#
#   Bump piri on staging: Fix tenant lock race (fil-forge/piri#212)
#
# Every #N and GH-N in the subject is qualified with the source repository. A
# bare #N would link to an issue in this repository once the commit lands on
# main, and with a closing keyword ("Fixes #N") close it. GitHub still appends
# the bump pull request's own number on merge, and the promotion scripts read
# that trailing "(#N)" as the bump's pull request, so the title must hold no
# other bare one.
#
# The subject is untrusted free text. Only its first line is used, control and
# format characters become spaces, backticks become quotes because Slack
# alerts quote the title in a code span, and an @ that would mention a person
# or team is dropped. A title longer than MAX_LENGTH characters is cut at a
# word boundary, so a reference is never shortened into a different one. With
# no commit, a commit whose message cannot be read, or nothing left of the
# subject, the title names the digest instead:
#
#   Bump piri on staging to sha256:6c17e7e
#
# Usage:
#   compose-bump-title.sh SERVICE STAGE DIGEST [SOURCE_REPO COMMIT]
#
# STAGE is the words after the service, such as "on staging". SOURCE_REPO and
# COMMIT may be empty. A failed lookup prints a workflow warning on stderr and
# never fails the script. Needs bash, jq and gh; every publisher repository is
# public, so any GH_TOKEN reads it.
set -euo pipefail

MAX_LENGTH=120

case "${1-}" in
  -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

if [ $# -ne 3 ] && [ $# -ne 5 ]; then
  echo "usage: compose-bump-title.sh SERVICE STAGE DIGEST [SOURCE_REPO COMMIT]" >&2
  exit 2
fi
service=$1 stage=$2 digest=$3 source_repo=${4-} commit=${5-}

[[ "$service" =~ ^[a-z][a-z0-9_]*$ ]] \
  || { echo "compose-bump-title.sh: malformed service '$service'" >&2; exit 2; }
[ -n "$stage" ] \
  || { echo "compose-bump-title.sh: empty stage wording" >&2; exit 2; }
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || { echo "compose-bump-title.sh: malformed digest '$digest'" >&2; exit 2; }
[[ -z "$source_repo" || "$source_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || { echo "compose-bump-title.sh: malformed source repository '$source_repo'" >&2; exit 2; }
[[ -z "$commit" || "$commit" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "compose-bump-title.sh: malformed commit '$commit'" >&2; exit 2; }
[[ -z "$commit" || -n "$source_repo" ]] \
  || { echo "compose-bump-title.sh: commit given without a source repository" >&2; exit 2; }

message=""
if [ -n "$commit" ]; then
  message=$(gh api "repos/$source_repo/commits/$commit" --jq .commit.message) || {
    echo "::warning::could not read $source_repo@${commit:0:7}; the title names the digest instead" >&2
    message=""
  }
fi

# jq rather than sed: it counts characters rather than bytes, so a cut never
# splits one, and its regular expressions have the lookbehind that tells a
# bare #N from one already qualified.
printf '%s' "$message" | jq --raw-input --raw-output --slurp \
  --arg service "$service" \
  --arg stage "$stage" \
  --arg digest "$digest" \
  --arg repo "$source_repo" \
  --arg quote "'" \
  --argjson max "$MAX_LENGTH" '
  def clean:
    (split("\n")[0] // "")
    | gsub("[\\p{Cc}\\p{Cf}]"; " ")
    | gsub("\\s+"; " ")
    | sub("^ "; "")
    | sub(" $"; "")
    | gsub("`"; $quote)
    | gsub("(?<![\\w.@])@(?=[A-Za-z0-9])"; "");

  def qualify:
    gsub("(?<![\\w/])(?:#|GH-)(?<n>[0-9]+)\\b"; "\($repo)#\(.n)");

  # Cut at the last space that fits, leaving room for the ellipsis. A subject
  # with no space in reach loses its trailing reference fragment instead.
  def cap($budget):
    if length <= $budget then .
    else .[:$budget - 1] as $cut
      | (if ($cut | test(" ")) then $cut | sub(" [^ ]*$"; "")
         else $cut | sub("[^ ]*#[0-9]*$"; "") end)
      | sub("[ ,;:.-]+$"; "")
      | . + "…"
    end;

  clean as $subject
  | if $repo == "" or $subject == "" then
      "Bump \($service) \($stage) to sha256:\($digest[7:14])"
    else
      "Bump \($service) \($stage): " as $prefix
      | $prefix + ($subject | qualify | cap($max - ($prefix | length)))
    end
'
