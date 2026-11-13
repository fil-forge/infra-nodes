#!/usr/bin/env bash
# Name the service commit behind an image bump, as one line of a Slack alert.
#
# A bump commit says which service image changed and nothing about what changed
# inside it, so an alert would name a digest nobody recognises. Bump deployed
# image writes the source commit into the body as a link, and that line is what
# this reads: matching it is the actual precondition for the lookup, stricter
# than checking the actor and the subject prefix.
#
# Usage:
#   git log -1 --format=%B | scripts/ci/service-commit-line.sh
#
# Prints the line, or nothing when the message is not a bump or the lookup
# fails. A rename, a deleted repository or a rate limit must not swallow the
# alert, so every failure prints nothing and exits 0, and the alert falls back
# to the infra-nodes commit alone.
#
# Every publisher repository is public, so GITHUB_TOKEN reads it through gh and
# no app token has to be minted on the failure path.
set -uo pipefail

body=$(cat)
line=$(printf '%s\n' "$body" |
  grep -oE '^- Commit: https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/commit/[0-9a-f]{40}$' |
  head -1) || true
if [ -z "$line" ]; then
  echo "no source commit link in the commit body" >&2
  exit 0
fi

line_url=${line#- Commit: }
path=${line_url#https://github.com/}
repo=${path%/commit/*}
sha=${path##*/commit/}

json=$(gh api "repos/$repo/commits/$sha") || {
  echo "::warning::could not read $repo@${sha:0:7}" >&2
  exit 0
}

# First line only: GITHUB_OUTPUT reads a newline as the end of the value and the
# rest as further outputs.
subject=$(printf '%s' "$json" | jq -r '.commit.message | split("\n")[0]')
# login is null when the commit email belongs to no GitHub account, so the git
# author name stands in and links no profile.
login=$(printf '%s' "$json" | jq -r '.author.login // ""')
if [ -n "$login" ]; then
  author="<https://github.com/$login|@$login>"
else
  author=$(printf '%s' "$json" | jq -r '.commit.author.name // "an unknown author"')
fi

echo "Service commit: \`$subject\` by $author (<$line_url|$repo@${sha:0:7}>)"
