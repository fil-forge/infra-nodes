#!/usr/bin/env bash
# Tests for scripts/ci/bump-deployed-image/compose-bump-title.sh, run from any
# machine:
#
#   scripts/ci/bump-deployed-image/tests/compose-bump-title.test.sh
#
# A stub gh first on PATH answers the commit lookup from a file, or fails when
# told to, so no case reaches GitHub. Each case compares the one line the
# script prints. Plain bash and jq, written for the bash 3.2 macOS ships as
# well as for a current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../compose-bump-title.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/compose-bump-title-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

STAGE="on staging"
REPO=fil-forge/piri
COMMIT=$(printf 'c%.0s' {1..40})
DIGEST=sha256:6c17e7e0000000000000000000000000000000000000000000000000000000ff
FALLBACK="Bump piri on staging to sha256:6c17e7e"

# The stub answers only the one lookup the script should make, so a wrong path
# fails the lookup and shows up as the digest title.
mkdir "$WORK/bin"
cat >"$WORK/bin/gh" <<STUB
#!/usr/bin/env bash
[ "\$*" = "api repos/$REPO/commits/$COMMIT --jq .commit.message" ] || exit 1
[ -z "\${STUB_FAIL-}" ] || { echo "HTTP 404" >&2; exit 1; }
cat "$WORK/message"
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

failures=0

pass() { printf '  ok   %s\n' "$1"; }
flunk() {
  printf '  FAIL %s\n' "$1"
  printf '       expected: %s\n' "$2"
  printf '       actual:   %s\n' "$3"
  failures=$((failures + 1))
}

# expect <description> <expected title> <commit message> [<source repo> <commit>]
expect() {
  local description=$1 expected=$2 actual
  printf '%s\n' "$3" >"$WORK/message"
  actual=$(cd "$WORK" && "$SCRIPT" piri "$STAGE" "$DIGEST" "${4-$REPO}" "${5-$COMMIT}" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    pass "$description"
  else
    flunk "$description" "$expected" "$actual"
  fi
}

# A subject of exactly <words> words: "Refactor" and then "lorem" repeated.
words() {
  printf 'Refactor'
  printf ' lorem%.0s' $(seq 2 "$1")
}

echo "compose-bump-title.sh"

expect "a squash subject's trailing pull request is qualified" \
  "Bump piri on staging: Fix tenant lock race (fil-forge/piri#212)" \
  "Fix tenant lock race (#212)"

expect "references mid-text are qualified, closing keyword or not" \
  "Bump piri on staging: Fixes fil-forge/piri#12, see fil-forge/piri#13 and fil-forge/piri#14" \
  "Fixes #12, see GH-13 and #14"

expect "a reference to another repository is left alone" \
  "Bump piri on staging: Revert fil-forge/sprue#40" \
  "Revert fil-forge/sprue#40"

expect "a hash that is no reference is left alone" \
  "Bump piri on staging: Use url#fragment and #main" \
  "Use url#fragment and #main"

expect "only the first line is used" \
  "Bump piri on staging: Add tenant quotas (fil-forge/piri#7)" \
  "Add tenant quotas (#7)

Closes #3 on the way."

expect "backticks become quotes, other shell syntax stays literal" \
  "Bump piri on staging: Quote \"a\" and 'b' with 'c' and \$(touch pwned) \$HOME" \
  "Quote \"a\" and 'b' with \`c\` and \$(touch pwned) \$HOME
second line"

expect "control characters become single spaces" \
  "Bump piri on staging: Fix the tab and the carriage return" \
  "$(printf 'Fix\tthe tab\033and the carriage return\r')"

expect "a long subject is cut at a word boundary" \
  "Bump piri on staging: $(words 15)…" \
  "$(words 30)"

expect "a cut never shortens a reference" \
  "Bump piri on staging: $(words 12) abcde…" \
  "$(words 12) abcde #212"

expect "a subject of exactly the maximum length is kept whole" \
  "Bump piri on staging: $(words 15)abcdef" \
  "$(words 15)abcdef"

expect "an empty message falls back to the digest" \
  "$FALLBACK" ""

expect "a blank first line falls back to the digest" \
  "$FALLBACK" "$(printf '  \t \nBody text')"

expect "a mention of a person or team loses its @" \
  "Bump piri on staging: Thanks alice and fil-forge/storage, mail a@b.io" \
  "Thanks @alice and @fil-forge/storage, mail a@b.io"

expect "no commit falls back to the digest" \
  "$FALLBACK" "Fix tenant lock race (#212)" "" ""

STUB_FAIL=1 expect "a failed lookup falls back to the digest" \
  "$FALLBACK" "Fix tenant lock race (#212)"

if STUB_FAIL=1 "$SCRIPT" piri "$STAGE" "$DIGEST" "$REPO" "$COMMIT" 2>&1 >/dev/null | grep -q '^::warning::could not read fil-forge/piri@ccccccc'; then
  pass "a failed lookup prints a workflow warning"
else
  flunk "a failed lookup prints a workflow warning" "::warning::could not read fil-forge/piri@ccccccc..." "no such line on stderr"
fi

if [ -e "$WORK/pwned" ]; then
  flunk "the subject is never run" "no file $WORK/pwned" "it exists"
else
  pass "the subject is never run"
fi

if "$SCRIPT" piri "$STAGE" sha256:6c17e7e "$REPO" "$COMMIT" >/dev/null 2>&1; then
  flunk "a malformed digest is refused" "a non-zero exit" "exit 0"
else
  pass "a malformed digest is refused"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
