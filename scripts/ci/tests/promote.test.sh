#!/usr/bin/env bash
# Tests for scripts/ci/promote.sh and the helpers of promote-prod.yml, run from
# any machine:
#
#   scripts/ci/tests/promote.test.sh
#
# promote.sh pushes to origin and opens pull requests, so it never runs against
# this checkout. Each case copies it, set-node-pin.sh and the prod helpers into
# a fresh git repository with a bare origin and a few nodes, and puts a stub gh
# first on PATH. The stub answers from files in a temporary directory and
# appends every call to a log the assertions read.
#
# Plain bash, git and jq, written for the bash 3.2 macOS ships as well as for a
# current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CI="$HERE/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/promote-test.XXXXXX")"
trap '[ -n "${KEEP-}" ] || rm -rf "$WORK"' EXIT

# The global git config of whoever runs this, commit signing say, stays out.
printf '[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' >"$WORK/gitconfig"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export APP_SLUG=fil-forge-bot
unset BASE TEST_RUN_URL GITHUB_OUTPUT

digest() { printf 'sha256:%064d' "$1"; }
PIRI_OLD=$(digest 1)
PIRI_NEW=$(digest 2)
INGOT=$(digest 9)
COMMIT_OLD=$(printf 'a%.0s' {1..40})
COMMIT_NEW=$(printf 'b%.0s' {1..40})

failures=0
current=""

pass() { printf '  ok   %s\n' "$current: $1"; }
flunk() {
  printf '  FAIL %s\n' "$current: $1"
  failures=$((failures + 1))
}
check() { # check <description> <command...>
  local description="$1"
  shift
  if "$@"; then pass "$description"; else flunk "$description"; fi
}

# --- Stubs -------------------------------------------------------------------

write_gh_stub() {
  cat >"$1/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_STATE/calls"
# The value following a flag, empty if the flag is absent.
arg() {
  local flag=$1
  shift
  while [ $# -gt 0 ]; do
    [ "$1" = "$flag" ] && { echo "${2-}"; return; }
    shift
  done
}
case "$1 $2" in
  "pr list")   cat "$STUB_STATE/pr_url" 2>/dev/null; exit 0 ;;
  "pr create") cp "$(arg --body-file "$@")" "$STUB_STATE/body"; echo https://github.com/fil-forge/infra-nodes/pull/1; exit 0 ;;
  "pr edit")   cp "$(arg --body-file "$@")" "$STUB_STATE/body"; exit 0 ;;
  "pr view")   cat "$STUB_STATE/armed" 2>/dev/null || echo false; exit 0 ;;
  pr\ *)       exit 0 ;;
esac
[ "$1" = api ] || exit 1
for path in "$@"; do
  case "$path" in
    /users/*)                echo 4242; exit 0 ;;
    orgs/*/versions*)        exit 0 ;;
    repos/*/compare/*)       cat "$STUB_STATE/compare.json"; exit 0 ;;
    repos/*/actions/runs/*)  jq -r "$(arg --jq "$@")" "$STUB_STATE/jobs.json"; exit 0 ;;
  esac
done
exit 1
STUB
  chmod +x "$1/gh"
}

# --- Fixture -----------------------------------------------------------------

# pins <file> <piri digest>: an apps/versions.env pinning piri and ingot.
pins() {
  mkdir -p "$(dirname "$1")"
  printf 'PIRI_IMAGE=ghcr.io/fil-forge/piri:main@%s\n\nINGOT_IMAGE=ghcr.io/fil-forge/ingot:main@%s\n' "$2" "$INGOT" >"$1"
}

# A repository whose history holds two dev bumps of piri, each naming the
# commit it was built from. Staging has taken the second; dev too. Both prod
# nodes still pin the first.
setup() {
  current="$1"
  CASE="$WORK/case-$((++case_count))"
  REPO="$CASE/repo"
  STUB_STATE="$CASE/state"
  export STUB_STATE
  mkdir -p "$CASE/bin" "$STUB_STATE" "$REPO/scripts/ci/promote-prod"
  write_gh_stub "$CASE/bin"
  PATH="$CASE/bin:$ORIGINAL_PATH"
  echo '[{"status":"ahead","behind_by":0,"total_commits":1,"commits":[{"sha":"'"$COMMIT_NEW"'","commit":{"message":"Read blobs from a path (#5)"}}]}]' \
    >"$STUB_STATE/compare.json"

  git init --quiet --bare "$CASE/origin.git"
  cd "$REPO"
  git init --quiet
  cp "$CI/promote.sh" "$CI/set-node-pin.sh" scripts/ci/
  cp "$CI/promote-prod/"*.sh scripts/ci/promote-prod/
  for node in staging/eu-central-3 prod/us-east-2 prod/eu-west-1; do
    pins "nodes/$node/apps/versions.env" "$(digest 0)"
    echo "FILONE_NODE=$node" >"nodes/$node/node.env"
  done
  pins nodes/dev/apps/versions.env "$(digest 0)"
  commit "Seed the nodes"

  pins nodes/dev/apps/versions.env "$PIRI_OLD"
  commit "Bump piri on dev to sha256:0000000 (#10)" "- Commit: https://github.com/fil-forge/piri/commit/$COMMIT_OLD"
  for node in staging/eu-central-3 prod/us-east-2 prod/eu-west-1; do
    pins "nodes/$node/apps/versions.env" "$PIRI_OLD"
  done
  commit "Promote dev's images everywhere"

  pins nodes/dev/apps/versions.env "$PIRI_NEW"
  commit "Bump piri on dev to sha256:0000000 (#11)" "- Commit: https://github.com/fil-forge/piri/commit/$COMMIT_NEW"
  pins nodes/staging/eu-central-3/apps/versions.env "$PIRI_NEW"
  commit "Promote dev's images to staging (#12)"

  git remote add origin "$CASE/origin.git"
  git push --quiet origin main
}

ORIGINAL_PATH="$PATH"
case_count=0

commit() {
  git add -A
  if [ $# -gt 1 ]; then
    git commit --quiet -m "$1" -m "$2"
  else
    git commit --quiet -m "$1"
  fi
}

# Runs promote.sh in the fixture, keeping its output.
promote() {
  if scripts/ci/promote.sh "$@" >"$CASE/out" 2>"$CASE/err"; then
    status=0
  else
    status=$?
  fi
}

origin_head() { git --git-dir="$CASE/origin.git" rev-parse --verify --quiet "refs/heads/$1"; }
has_branch() { origin_head "$1" >/dev/null; }
calls_contain() { grep -qF -- "$1" "$STUB_STATE/calls"; }
changed_files() { git --git-dir="$CASE/origin.git" diff --name-only "$1^" "$1"; }

# --- Cases -------------------------------------------------------------------

echo "promote.sh"

setup "staging keeps its branch"
pins nodes/dev/apps/versions.env "$(digest 3)"
commit "Bump piri on dev (#13)"
git push --quiet origin main
promote staging --dry-run
check "would push bot/promote-staging" grep -qF "would push bot/promote-staging" "$CASE/err"

setup "staging keeps its title"
pins nodes/dev/apps/versions.env "$(digest 3)"
commit "Bump piri on dev (#13)"
git push --quiet origin main
promote staging --dry-run
check "the commit is titled Promote dev's images to staging" grep -qxF "Promote dev's images to staging" "$CASE/out"

setup "a prod node gets a branch of its own"
promote prod/us-east-2
check "origin has bot/promote-prod-us-east-2" has_branch bot/promote-prod-us-east-2

setup "a prod promotion pins only its own node"
promote prod/us-east-2
check "only nodes/prod/us-east-2/apps/versions.env changes" \
  test "$(changed_files bot/promote-prod-us-east-2)" = nodes/prod/us-east-2/apps/versions.env

setup "a prod promotion takes staging's pins"
promote prod/us-east-2
check "piri is pinned at staging's digest" \
  test "$(git --git-dir="$CASE/origin.git" show bot/promote-prod-us-east-2:nodes/prod/us-east-2/apps/versions.env | head -n 1)" \
  = "PIRI_IMAGE=ghcr.io/fil-forge/piri:main@$PIRI_NEW"

setup "a prod pull request is titled after its node"
promote prod/us-east-2
check "gh pr create names the node" \
  calls_contain "pr create --base main --head bot/promote-prod-us-east-2 --title Promote staging's images to prod/us-east-2"

setup "a prod pull request lists what the service brings"
promote prod/us-east-2
check "the body lists fil-forge/piri#5" grep -qF -- "- fil-forge/piri#5 " "$STUB_STATE/body"

setup "a prod pull request links the staging test"
TEST_RUN_URL=https://github.com/fil-forge/infra-nodes/actions/runs/77 promote prod/us-east-2
check "the body names the Test nodes run" \
  grep -qF "staging passed Test nodes on that commit in https://github.com/fil-forge/infra-nodes/actions/runs/77." "$STUB_STATE/body"

setup "a prod promotion builds on BASE"
tested=$(git rev-parse HEAD)
pins nodes/staging/eu-central-3/apps/versions.env "$(digest 3)"
commit "Promote dev's images to staging (#14)"
git push --quiet origin main
BASE=$tested promote prod/us-east-2
check "the branch's parent is BASE" \
  test "$(git --git-dir="$CASE/origin.git" rev-parse bot/promote-prod-us-east-2^)" = "$tested"

setup "two prod nodes are promoted apart"
promote prod/us-east-2
promote prod/eu-west-1
check "bot/promote-prod-eu-west-1 changes only its own node" \
  test "$(changed_files bot/promote-prod-eu-west-1)" = nodes/prod/eu-west-1/apps/versions.env

setup "a matching prod node closes its pull request"
promote prod/us-east-2
pins nodes/prod/us-east-2/apps/versions.env "$PIRI_NEW"
commit "Promote staging's images to prod/us-east-2 (#15)"
git push --quiet origin main
echo https://github.com/fil-forge/infra-nodes/pull/1 >"$STUB_STATE/pr_url"
promote prod/us-east-2
check "gh pr close is called after deleting the branch" calls_contain "pr close https://github.com/fil-forge/infra-nodes/pull/1"

setup "a branch a person pushed is left alone"
promote prod/us-east-2
git fetch --quiet origin bot/promote-prod-us-east-2
git checkout --quiet -b held FETCH_HEAD
git commit --quiet --amend --no-edit --author "A Person <person@example.com>"
git push --quiet --force origin held:bot/promote-prod-us-east-2
git checkout --quiet main
held=$(git rev-parse held)
echo https://github.com/fil-forge/infra-nodes/pull/1 >"$STUB_STATE/pr_url"
pins nodes/dev/apps/versions.env "$(digest 3)"
commit "Bump piri on dev (#16)"
git push --quiet origin main
promote prod/us-east-2
check "origin still has the person's head" test "$(origin_head bot/promote-prod-us-east-2)" = "$held"

setup "a new head disables auto-merge"
echo https://github.com/fil-forge/infra-nodes/pull/1 >"$STUB_STATE/pr_url"
echo true >"$STUB_STATE/armed"
promote prod/us-east-2
check "gh pr merge --disable-auto is called" calls_contain "pr merge --disable-auto"

rejected_targets="prod staging/eu-central-3 prod/nowhere prod/../dev dev"
for target in $rejected_targets; do
  setup "target $target"
  promote "$target" --dry-run
  check "is rejected" test "$status" -ne 0
done

echo "promote-prod/select.sh"

setup "select lists every prod node"
check "both prod nodes are in the matrix" \
  test "$(scripts/ci/promote-prod/select.sh)" = '{"include":[{"node":"prod/eu-west-1"},{"node":"prod/us-east-2"}]}'

echo "promote-prod/staging-passed.sh"

# jobs <staging conclusion> <dev conclusion>: a run's jobs, as the API lists them.
jobs() {
  jq -n --arg staging "$1" --arg dev "$2" \
    '{jobs: [{name: "Test dev", conclusion: $dev}, {name: "Test staging/eu-central-3", conclusion: $staging}]}'
}
gate_cases="success:success:true success:failure:true failure:success:false cancelled:success:false"
for gate_case in $gate_cases; do
  staging=${gate_case%%:*}
  rest=${gate_case#*:}
  dev=${rest%%:*}
  expected=${rest#*:}
  setup "staging $staging, dev $dev"
  jobs "$staging" "$dev" >"$STUB_STATE/jobs.json"
  check "prints passed=$expected" test "$(scripts/ci/promote-prod/staging-passed.sh 77 2>/dev/null)" = "passed=$expected"
done

setup "a run without a staging job"
echo '{"jobs": [{"name": "Test dev", "conclusion": "success"}]}' >"$STUB_STATE/jobs.json"
check "prints passed=false" test "$(scripts/ci/promote-prod/staging-passed.sh 77 2>/dev/null)" = "passed=false"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
