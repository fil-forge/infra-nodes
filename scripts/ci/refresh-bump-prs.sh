#!/usr/bin/env bash
# Rebuild every open bump pull request on top of current main.
#
# The ruleset requires a branch to be up to date before it merges, so one bump
# landing leaves every other open bump behind main and unmergeable until
# something moves it. This moves them. With two services publishing
# independently, nothing else ever would.
#
# Rebuilding is safe because of what a bump pull request is. It asks for one
# thing, that the node run one digest, and its branch is main plus that one
# line. So it can be regenerated from current main rather than merged, which is
# how bump-deployed-image.yml builds it in the first place.
#
# Usage:
#   APP_SLUG=fil-forge-bot scripts/ci/refresh-bump-prs.sh
#
# Reads APP_SLUG, the GitHub App whose pull requests get refreshed and whose
# identity the rebuilt commits carry. gh reads its own credentials, GH_TOKEN
# included.
#
# Force-pushes bump branches, closes superseded pull requests and enables
# auto-merge, so .github/workflows/refresh-bump-prs.yml is where it belongs. A
# person running it needs push rights on bot/bump-* and gets the same effects.
#
# Prerequisites:
#   - a git work tree on main, with origin fetchable and pushable
#   - gh authenticated
#   - writes the local git identity (user.name, user.email) of the work tree
set -euo pipefail

case "${1-}" in
  -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")        ;;
  *)         echo "usage: APP_SLUG=<app> scripts/ci/refresh-bump-prs.sh" >&2; exit 2 ;;
esac

: "${APP_SLUG:?set APP_SLUG to the GitHub App that opens the bump pull requests}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="nodes/dev/apps/versions.env"
cd "$ROOT"

# The digest one commit pins a service at, empty if it pins none. The pin
# carries a tag as well as a digest and only the digest is read here; a tag
# somebody moved is caught by set-node-pin.sh when the branch is rebuilt.
pin_at() {
  local key
  key="$(tr '[:lower:]' '[:upper:]' <<<"$2")_IMAGE"
  git show "$1:$FILE" | sed -nE "s|^${key}=[^@]+@(sha256:[0-9a-f]{64})[[:blank:]]*\$|\1|p"
}

# Attribute the commits to the app, as the bump workflow does. A commit from
# anyone else would need the extra approval the ruleset asks for on
# unattributed changes.
bot_id=$(gh api "/users/${APP_SLUG}%5Bbot%5D" --jq .id)
git config user.name "${APP_SLUG}[bot]"
git config user.email "${bot_id}+${APP_SLUG}[bot]@users.noreply.github.com"

# Only what the app opened here. This repository allows forks, and a fork can
# name its branch anything: matching on the branch name alone would pick up a
# pull request whose head is no ref of ours. --limit, because the default page
# of 30 could hide a bump behind a queue of Dependabot pull requests.
opened=$(gh pr list --state open --limit 100 \
  --author "app/${APP_SLUG}" \
  --json headRefName,isCrossRepository \
  --jq '.[] | select(.isCrossRepository | not) | .headRefName')
# Its own statement, so `|| true` covers grep finding no bump and nothing else.
# On one pipeline it would also swallow an outage or an expired token, and the
# run would report having refreshed everything.
matched=$(grep -E '^bot/bump-[a-z_]+-image-dev$' <<<"$opened" || true)
if [ -z "$matched" ]; then
  echo "no open bump pull requests"
  exit 0
fi

# After listing, so a branch pushed while this job started is here.
git fetch --quiet --force origin main "+refs/heads/bot/*:refs/remotes/origin/bot/*"

# On fd 3, so a git or gh command inside cannot eat the rest of the list.
while IFS= read -r branch <&3; do
  echo "::group::$branch"
  service=${branch#bot/bump-}
  service=${service%-image-dev}

  # Twice at most. The lease below fails when a publish replaces the branch
  # mid-run, and that publish built on the main this run is refreshing past, so
  # what it left needs the same rebuild.
  for attempt in 1 2; do
    if ! head=$(git rev-parse --verify --quiet "origin/$branch"); then
      echo "pushed after this run fetched; that push queued another run"
      break
    fi

    if git merge-base --is-ancestor origin/main "origin/$branch"; then
      echo "already on current main"
      break
    fi

    # What the pull request asks for, read off the branch rather than passed
    # in, so a refresh cannot deploy a digest nobody published.
    digest=$(pin_at "origin/$branch" "$service")
    if [ -z "$digest" ]; then
      echo "::error::$branch pins no digest for $service"
      exit 1
    fi
    main_digest=$(pin_at origin/main "$service")
    if [ -z "$main_digest" ]; then
      echo "::error::main pins no digest for $service"
      exit 1
    fi

    if [ "$main_digest" = "$digest" ]; then
      # The URL now, while the branch still resolves to the one open pull
      # request; every merged bump reused this branch name. The deletion
      # carries the same lease as the rebuild push below, because a publish may
      # have replaced the branch after $head was read, and deleting what it
      # pushed would throw away a digest nobody deployed yet.
      url=$(gh pr view "$branch" --json url --jq .url)
      if git push --force-with-lease="$branch:$head" --quiet origin ":$branch"; then
        echo "main already pins $service at $digest; closing"
        gh pr comment "$url" \
          --body "Superseded: main already pins \`$service\` at \`$digest\`."
        # Usually a no-op: deleting the head closes the pull request.
        gh pr close "$url" 2>/dev/null || true
        break
      fi
    else
      # Someone else moved this service while the branch sat open, so which
      # digest the node should run is a question rather than an edit. Rebuilding
      # would answer it by rolling main back to this branch. Left alone, the
      # pull request shows the conflict it really has.
      base_digest=$(pin_at "$(git merge-base origin/main "origin/$branch")" "$service")
      if [ "$main_digest" != "$base_digest" ]; then
        echo "main moved $service to $main_digest, where this branch was built from $base_digest; leaving it for a person"
        break
      fi

      # Rebuilding keeps the original message, which is the whole reason this
      # beats re-running the bump: the link to the pull request that published
      # the image survives.
      message=$(git log -1 --format=%B "origin/$branch")

      git checkout --quiet -B "$branch" origin/main
      changed=$(scripts/ci/set-node-pin.sh "$service" "$digest" | sed -n 's/^changed=//p')
      if [ "$changed" != true ]; then
        echo "::error::$FILE pins $service at $main_digest and rewriting it to $digest changed nothing"
        exit 1
      fi
      git commit --quiet --all --message "$message"

      # --force-with-lease, where the bump workflow pushes plain --force. The
      # asymmetry is deliberate: a bump carries a digest nobody has deployed
      # yet and should win, while a refresh only moves a branch forward and has
      # nothing worth overwriting a newer publish for. A bump that wins on a
      # stale base is caught by the run its own push starts.
      if git push --force-with-lease="$branch:$head" --quiet origin "$branch"; then
        armed=$(gh pr view "$branch" --json autoMergeRequest --jq '.autoMergeRequest != null')
        if [ "$armed" != true ]; then
          gh pr merge --auto --squash "$branch"
        fi
        echo "rebuilt on $(git rev-parse --short origin/main), auto-merge enabled"
        break
      fi
    fi

    if [ "$attempt" = 2 ]; then
      echo "replaced twice while this ran; leaving it to the run those pushes queued"
      break
    fi
    echo "replaced while this ran; re-reading the branch"
    git fetch --quiet --force origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  done
  echo "::endgroup::"
done 3<<<"$matched"
