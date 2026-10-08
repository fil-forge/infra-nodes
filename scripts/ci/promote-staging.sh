#!/usr/bin/env bash
# Open, refresh or close the pull request that promotes dev's images to staging.
#
# Dev's pins move on their own: every image a service publishes gets a bump
# pull request that the bot merges. Staging's move only when a person says so.
# This keeps one pull request, "Promote dev's images to staging", that sets
# every staging pin to what dev pins now, and lists what each service brings
# over what staging runs. It never enables auto-merge: merging it is the
# promotion.
#
# Everything it does is derived from main, so it runs on every push to main:
#   - staging already pins what dev pins: close the pull request, if one is open
#   - otherwise: rebuild bot/promote-staging as main plus staging's new pins, and
#     open or refresh the pull request
# A branch someone pushed to by hand, to hold a service back say, is left alone
# while its pull request is open.
#
# Usage:
#   APP_SLUG=fil-forge-bot scripts/ci/promote-staging.sh [--dry-run]
#
# --dry-run builds the branch in the local work tree and prints the message,
# and pushes, opens and closes nothing.
#
# Reads APP_SLUG, the GitHub App that opens the pull request and whose identity
# its commit carries. gh reads its own credentials, GH_TOKEN included.
#
# Prerequisites:
#   - a git work tree with origin fetchable and pushable, and full history
#     (each pin's source commit is read off the dev bump that first carried it)
#   - gh authenticated, for the compare API and the pull request
#   - writes the local git identity (user.name, user.email) of the work tree
set -euo pipefail

DRY_RUN=false
case "${1-}" in
  -h|--help)  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --dry-run)  DRY_RUN=true ;;
  "")         ;;
  *)          echo "usage: APP_SLUG=<app> scripts/ci/promote-staging.sh [--dry-run]" >&2; exit 2 ;;
esac

: "${APP_SLUG:?set APP_SLUG to the GitHub App that opens the promotion pull request}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BRANCH=bot/promote-staging
NODE=staging/eu-central-3
DEV_FILE=nodes/dev/apps/versions.env
STAGING_FILE=nodes/$NODE/apps/versions.env
SUBJECT="Promote dev's images to staging"

# The services a node pins, and the repository each publishes from, mirroring
# set-node-pin.sh and bump-deployed-image.yml.
SERVICES=(piri ingot)
repo_of() {
  case "$1" in
    piri)  echo fil-forge/piri ;;
    ingot) echo fil-forge/ingot ;;
  esac
}

# The digest a file at a commit pins a service at, empty if it pins none.
pin_at() {
  local key
  key="$(tr '[:lower:]' '[:upper:]' <<<"$3")_IMAGE"
  git show "$1:$2" | sed -nE "s|^${key}=[^@]+@(sha256:[0-9a-f]{64})[[:blank:]]*\$|\1|p"
}

# The commit a digest was built from, empty if unknown. Every digest a node runs
# reached dev first, through a bump whose message names the commit it was
# published from; the oldest commit on main that put the digest in dev's file
# is that bump. A digest dispatched by hand has no commit.
source_commit() {
  local service=$1 digest=$2 bump
  bump=$(git log --reverse --format=%H -S "$digest" origin/main -- "$DEV_FILE" | head -n 1)
  [ -n "$bump" ] || return 0
  git log -1 --format=%B "$bump" \
    | sed -nE "s|^- Commit: https://github\.com/$(repo_of "$service")/commit/([0-9a-f]{40})\$|\1|p" \
    | head -n 1
}

# What a service brings between two of its commits, one line per commit, oldest
# first. Squash-merged titles end in "(#123)", which here would link to this
# repository's pull request 123; each becomes a link to the service's pull
# request instead. The links are explicit, because GitHub renders a bare
# reference as the title of what it names, which the line already starts with,
# and does not link a bare commit hash from another repository at all.
changes() {
  local repo=$1 from=$2 to=$3
  gh api "repos/$repo/compare/$from...$to" \
    --jq '.commits[] | "- " + (.commit.message | split("\n")[0])
      + " ([" + .sha[0:7] + "](https://github.com/'"$repo"'/commit/" + .sha + "))"' \
    | sed -E "s|\(#([0-9]+)\)|([$repo#\1](https://github.com/$repo/pull/\1))|g"
}

git fetch --quiet --force origin main "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null \
  || git fetch --quiet --force origin main
old_head=$(git rev-parse --verify --quiet "origin/$BRANCH" || true)

# Only a pull request the app opened, from this repository.
pr_url=""
if [ "$DRY_RUN" = false ]; then
  pr_url=$(gh pr list --state open --head "$BRANCH" --author "app/${APP_SLUG}" \
    --json url,isCrossRepository --jq '[.[] | select(.isCrossRepository | not)][0].url // ""')
fi

# Which services differ, and the message describing the promotion.
body=$(mktemp)
trap 'rm -f "$body"' EXIT
moving=()
{
  echo "Sets every staging pin in \`$STAGING_FILE\` to what"
  echo "\`$DEV_FILE\` pins on \`main\`. Merging this is the promotion: the node picks"
  echo "it up on its next reconcile pass, waits for a safe proving window and restarts each"
  echo "service that changed."
  echo
  echo "This pull request is rebuilt on every push to \`main\` and closed once staging matches"
  echo "dev, so edits to it are overwritten unless they are pushed to \`$BRANCH\` by hand."
} >"$body"
for service in "${SERVICES[@]}"; do
  dev_digest=$(pin_at origin/main "$DEV_FILE" "$service")
  staging_digest=$(pin_at origin/main "$STAGING_FILE" "$service")
  if [ -z "$dev_digest" ] || [ -z "$staging_digest" ]; then
    echo "::error::main does not pin $service on both dev and staging"
    exit 1
  fi
  [ "$dev_digest" != "$staging_digest" ] || continue
  moving+=("$service:$dev_digest")

  repo=$(repo_of "$service")
  from=$(source_commit "$service" "$staging_digest")
  to=$(source_commit "$service" "$dev_digest")
  {
    echo
    echo "## $service"
    echo
    echo "\`sha256:${staging_digest:7:7}\` → \`sha256:${dev_digest:7:7}\`"
    echo
    if [ -n "$from" ] && [ -n "$to" ]; then
      echo "What $repo brings over staging's pin, \`${from:0:7}..${to:0:7}\`:"
      echo
      # A change list the API will not give is no reason to hold the promotion.
      changes "$repo" "$from" "$to" \
        || echo "The change list could not be fetched; see https://github.com/$repo/compare/$from...$to."
    else
      # A digest dispatched by hand names no commit.
      echo "No change list: the commit $( [ -n "$from" ] && echo "dev's" || echo "staging's" ) digest was built from is unknown."
    fi
  } >>"$body"
done

if [ ${#moving[@]} -eq 0 ]; then
  echo "staging already pins what dev pins"
  if [ -n "$pr_url" ] && [ -n "$old_head" ]; then
    if git push --force-with-lease="$BRANCH:$old_head" --quiet origin ":$BRANCH"; then
      gh pr comment "$pr_url" --body "Superseded: staging already pins what dev pins."
      # Usually a no-op: deleting the head closes the pull request.
      gh pr close "$pr_url" 2>/dev/null || true
      echo "closed $pr_url"
    fi
  fi
  exit 0
fi

# A branch whose head the app did not commit was pushed to by a person, who
# wanted something other than dev's pins. Rebuilding would undo that, while its
# pull request is open; once that is merged or closed, the branch is fair game.
if [ -n "$old_head" ] && [ -n "$pr_url" ]; then
  author=$(git log -1 --format=%an "$old_head")
  if [ "$author" != "${APP_SLUG}[bot]" ]; then
    echo "$BRANCH was last pushed by $author, not ${APP_SLUG}[bot]; leaving it for a person"
    exit 0
  fi
fi

# Attribute the commit to the app, as the bump workflow does.
if [ "$DRY_RUN" = false ]; then
  bot_id=$(gh api "/users/${APP_SLUG}%5Bbot%5D" --jq .id)
  git config user.name "${APP_SLUG}[bot]"
  git config user.email "${bot_id}+${APP_SLUG}[bot]@users.noreply.github.com"
fi

git checkout --quiet -B "$BRANCH" origin/main
# Staged after each pin: set-node-pin.sh asserts its own edit is one line,
# against the index.
for move in "${moving[@]}"; do
  scripts/ci/set-node-pin.sh --node "$NODE" "${move%%:*}" "${move#*:}" >/dev/null
  git add "$STAGING_FILE"
done
# Only what was staged above, whatever else the work tree holds.
git commit --quiet --file <(echo "$SUBJECT"; echo; cat "$body")

if [ "$DRY_RUN" = true ]; then
  echo "would push $BRANCH at $(git rev-parse --short HEAD), on main $(git rev-parse --short origin/main):" >&2
  git --no-pager show --stat --format='%n%B' HEAD
  exit 0
fi

# Already main plus these pins: nothing to push, and no new checks to run.
pushed=false
if [ -n "$old_head" ] \
  && [ "$(git rev-parse "$old_head^")" = "$(git rev-parse origin/main)" ] \
  && git diff --quiet "$old_head" HEAD; then
  echo "$BRANCH is already main plus dev's pins"
else
  git push --force-with-lease="$BRANCH:$old_head" --quiet origin "$BRANCH"
  pushed=true
  echo "pushed $BRANCH at $(git rev-parse --short HEAD)"
fi

if [ -z "$pr_url" ]; then
  pr_url=$(gh pr create --base main --head "$BRANCH" --title "$SUBJECT" --body-file "$body")
  echo "opened $pr_url"
else
  gh pr edit "$pr_url" --title "$SUBJECT" --body-file "$body"
  echo "refreshed $pr_url"
fi

# Someone may have enabled auto-merge for an earlier head. A new head is a new
# set of images, and merging it is a person's decision, so it goes.
armed=$(gh pr view "$pr_url" --json autoMergeRequest --jq '.autoMergeRequest != null')
if [ "$armed" = true ] && [ "$pushed" = true ]; then
  gh pr merge --disable-auto "$pr_url"
  echo "disabled auto-merge, which predates this head"
fi
