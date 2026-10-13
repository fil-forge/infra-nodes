#!/usr/bin/env bash
# Check that a node serves a customer end to end: create a tenant through Hilt,
# create a bucket on the node's Ingot, upload two objects, download them and
# compare. --cleanup then deletes everything the test created.
#
# The smoke test proves the services answer. This proves the write path works:
# Hilt mints the tenant and its key, Ingot authorizes against Hilt, encrypts to
# the tenant's key and stores the blobs on Piri, and serves them back.
#
# Usage:
#   scripts/ci/e2e-test.sh <node>
#   scripts/ci/e2e-test.sh <node> --cleanup
#
# Example:
#   E2E_RUN_ID=manual-1 HILT_PARTNER_KEY=... scripts/ci/e2e-test.sh dev
#   E2E_RUN_ID=manual-1 HILT_PARTNER_KEY=... scripts/ci/e2e-test.sh dev --cleanup
#
# The tenant and the bucket are both named infra-nodes-e2e-<node>-<run id>, so
# --cleanup finds them from the same inputs. It deletes only what the test
# recorded creating, in the order Hilt requires: objects, bucket, then the
# tenant is disabled and deleted. A delete that fails is retried three times;
# if it still fails, cleanup stops and keeps the tenant, because deleting a
# tenant whose bucket holds data leaks its storage for good.
#
# Environment:
#   HILT_PARTNER_KEY  bearer key for the node's Hilt Tenant API; never printed
#   E2E_RUN_ID        names the tenant and bucket; in GitHub Actions it
#                     defaults to $GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT
#   E2E_STATE_DIR     where the test leaves its S3 key and progress for
#                     --cleanup; defaults to a directory under $RUNNER_TEMP
#                     or $TMPDIR
#
# Hilt's URL, the region and Ingot's hostname come from nodes/<node>/node.env.
#
# In GitHub Actions the script writes failed_op, and from --cleanup
# leftover_tenant and leftover_bucket, to $GITHUB_OUTPUT.
#
# Prerequisites:
#   - curl, jq and the AWS CLI v2
set -euo pipefail

usage="usage: scripts/ci/e2e-test.sh <node> [--cleanup]"
case "${1-}" in
  -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")        echo "$usage" >&2; exit 2 ;;
  -*)        echo "unknown option: $1" >&2; exit 2 ;;
esac

NODE="$1"
shift
MODE="test"
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) MODE=cleanup; shift ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

PASS='  ✓'
FAIL='  ✗'

pass() { printf '%s %s\n' "$PASS" "$1"; }
fail() { printf '%s %s\n' "$FAIL" "$1"; }

# output — record a step output for the alert. A no-op outside GitHub Actions.
# One line, because GITHUB_OUTPUT reads a newline as the end of the value, and an
# error can quote a multi-line response such as a proxy's HTML page.
output() {
  [ -z "${GITHUB_OUTPUT-}" ] || printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" >>"$GITHUB_OUTPUT"
}

# abort — the first failed operation ends the run and names itself.
abort() {
  fail "$1"
  output failed_op "$1"
  exit 1
}

for tool in curl jq aws; do
  command -v "$tool" >/dev/null || abort "configuration — $tool not found in PATH"
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

NODE_ENV="nodes/$NODE/node.env"
[ -f "$NODE_ENV" ] || abort "configuration — no such node '$NODE': $NODE_ENV does not exist"

read_env() { sed -nE "s/^$1=(.*)\$/\1/p" "$NODE_ENV" | tail -1; }
HILT_URL="$(read_env HILT_URL)"
REGION="$(read_env REGION_LABEL)"
INGOT_HOSTNAME="$(read_env INGOT_HOSTNAME)"
[ -n "$HILT_URL" ] || abort "configuration — no HILT_URL in $NODE_ENV"
[ -n "$REGION" ] || abort "configuration — no REGION_LABEL in $NODE_ENV"
[ -n "$INGOT_HOSTNAME" ] || abort "configuration — no INGOT_HOSTNAME in $NODE_ENV"

[ -n "${HILT_PARTNER_KEY-}" ] || abort "configuration — HILT_PARTNER_KEY is not set"

if [ -z "${E2E_RUN_ID-}" ] && [ -n "${GITHUB_RUN_ID-}" ]; then
  E2E_RUN_ID="$GITHUB_RUN_ID-${GITHUB_RUN_ATTEMPT:-1}"
fi
[ -n "${E2E_RUN_ID-}" ] || abort "configuration — set E2E_RUN_ID to name this run's tenant and bucket"

# One name for both. Bucket names are unique across every tenant on a Hilt, so
# the run id keeps two runs, and two nodes on one Hilt, apart. FilOne names its
# tenants by UUID, so the prefix cannot collide with a customer's tenant.
NAME="infra-nodes-e2e-${NODE//\//-}-$E2E_RUN_ID"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] ||
  abort "configuration — '$NAME' is not a valid bucket name (lowercase, digits and hyphens, at most 63)"

STATE="${E2E_STATE_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/filone-e2e-$NAME}"
umask 077
mkdir -p "$STATE"

# Progress markers. Each is written before the call that creates the thing it
# names, so a call that times out after succeeding still gets cleaned up, and
# removed once the thing is known to be gone or known not to be ours.
TENANT_MARKER="$STATE/tenant"
BUCKET_MARKER="$STATE/bucket"

# The partner key reaches curl through a header file, so it never appears in a
# process listing.
AUTH_HEADER="$STATE/hilt-auth-header"
printf 'Authorization: Bearer %s\n' "$HILT_PARTNER_KEY" >"$AUTH_HEADER"
RESPONSE="$STATE/hilt-response"
trap 'rm -f "$AUTH_HEADER" "$RESPONSE" "$RESPONSE.err"' EXIT

# The S3 client reads only the files below. An operator running this by hand
# usually has AWS credentials in the environment, and those take precedence over
# any file.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE \
  AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3
export AWS_CONFIG_FILE="$STATE/aws-config"
export AWS_SHARED_CREDENTIALS_FILE="$STATE/aws-credentials"
export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""

main() {
  echo "=== End-to-end test of the $NODE node: $MODE ==="
  echo "  Hilt:   $HILT_URL"
  echo "  Ingot:  https://$INGOT_HOSTNAME ($REGION)"
  echo "  Tenant and bucket: $NAME"
  echo

  if [ "$MODE" = test ]; then
    run_test
    echo
    echo "OK: the node created a tenant and a bucket, and served back both objects"
  else
    run_cleanup
    echo
    echo "OK: deleted everything the test created"
  fi
}

run_test() {
  create_tenant
  create_access_key
  write_aws_config
  create_bucket
  upload_and_compare
}

run_cleanup() {
  local left_tenant="" left_bucket=""
  # Recorded up front and cleared as each thing goes, so whatever exit this
  # takes, the alert names what is still there.
  [ ! -f "$TENANT_MARKER" ] || left_tenant="$NAME"
  [ ! -f "$BUCKET_MARKER" ] || left_bucket="$NAME"
  output leftover_tenant "$left_tenant"
  output leftover_bucket "$left_bucket"

  if [ -f "$BUCKET_MARKER" ]; then
    [ -f "$AWS_SHARED_CREDENTIALS_FILE" ] ||
      abort "delete the bucket — the test recorded a bucket but left no S3 key to delete it with"
    if bucket_exists; then
      retry "delete small.bin" aws s3api delete-object --bucket "$NAME" --key small.bin
      retry "delete large.bin" aws s3api delete-object --bucket "$NAME" --key large.bin
      retry "delete the bucket" aws s3api delete-bucket --bucket "$NAME"
    else
      pass "delete the bucket — it does not exist"
    fi
    rm -f "$BUCKET_MARKER"
    output leftover_bucket ""
  fi

  if [ -f "$TENANT_MARKER" ]; then
    # Hilt deletes only a disabled tenant, and refuses S3 requests from one,
    # which is why the bucket goes first.
    retry "disable the tenant" hilt_expect POST "/tenants/$NAME/status" '{"status":"disabled"}' 204 404
    retry "delete the tenant" hilt_expect DELETE "/tenants/$NAME" "" 204
    rm -f "$TENANT_MARKER"
    output leftover_tenant ""
  fi

  rm -rf "$STATE"
}

create_tenant() {
  : >"$TENANT_MARKER"
  hilt_call PUT "/tenants/$NAME" "$(jq -nc --arg region "$REGION" '{region: $region}')"
  case "$HILT_STATUS" in
    201) pass "create the tenant" ;;
    200)
      # Not ours: cleanup must not delete it.
      rm -f "$TENANT_MARKER"
      abort "create the tenant — $NAME already exists; pick another E2E_RUN_ID"
      ;;
    *) abort "create the tenant — $(hilt_error)" ;;
  esac
}

# The key expires on its own two hours from now, so one a failed cleanup leaves
# behind stops working without anyone acting on it. Deleting the tenant deletes
# the key, so cleanup does not delete it separately.
create_access_key() {
  local expires body access_key secret_key
  expires="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)"
  body="$(jq -nc --arg expires "$expires" '{
    name: "e2e",
    expiresAt: $expires,
    permissions: [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:ListBucket",
      "s3:PutObject", "s3:GetObject", "s3:DeleteObject",
      "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
    ]
  }')"

  hilt_call POST "/tenants/$NAME/access-keys" "$body"
  [ "$HILT_STATUS" = 201 ] || abort "create an access key — $(hilt_error)"

  # The response is the only copy of the secret. It is read and then removed,
  # and never printed.
  access_key="$(jq -r '.accessKeyId // empty' "$RESPONSE")"
  secret_key="$(jq -r '.secretAccessKey // empty' "$RESPONSE")"
  rm -f "$RESPONSE"
  [ -n "$access_key" ] && [ -n "$secret_key" ] ||
    abort "create an access key — Hilt answered 201 without a key pair"
  [ "${GITHUB_ACTIONS-}" != true ] || echo "::add-mask::$secret_key"

  printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
    "$access_key" "$secret_key" >"$AWS_SHARED_CREDENTIALS_FILE"
  pass "create an access key, expiring $expires"
}

# Path-style addressing, because Ingot has no wildcard certificate, and the
# region the node signs with, because a mismatch fails every signature. The
# CLI's default checksums and its 8 MiB multipart switchover work against Ingot
# unchanged.
write_aws_config() {
  cat >"$AWS_CONFIG_FILE" <<EOF
[default]
region = $REGION
endpoint_url = https://$INGOT_HOSTNAME
cli_connect_timeout = 10
cli_read_timeout = 60
s3 =
  addressing_style = path
EOF
}

create_bucket() {
  local err
  : >"$BUCKET_MARKER"
  if err="$(aws s3 mb "s3://$NAME" 2>&1 >/dev/null)"; then
    pass "create the bucket"
    return
  fi
  # Another tenant's bucket, which cleanup must not touch.
  if grep -q BucketAlreadyExists <<<"$err"; then
    rm -f "$BUCKET_MARKER"
  fi
  abort "create the bucket — $(tail -3 <<<"$err" | tr '\n' ' ')"
}

upload_and_compare() {
  # Small enough for a single PutObject, and large enough to cross the CLI's
  # 8 MiB switchover into a two-part multipart upload. Ingot handles the two
  # paths separately.
  head -c 4096 /dev/urandom >"$STATE/small.bin"
  head -c $((16 * 1024 * 1024)) /dev/urandom >"$STATE/large.bin"

  attempt "upload small.bin with PutObject" \
    aws s3api put-object --bucket "$NAME" --key small.bin --body "$STATE/small.bin"
  attempt "upload large.bin with a multipart upload" \
    aws s3 cp "$STATE/large.bin" "s3://$NAME/large.bin"

  # Without this, a CLI that stopped choosing multipart would leave the test
  # passing on a path it no longer covers. A multipart ETag ends in -<parts>.
  local etag
  etag="$(aws s3api head-object --bucket "$NAME" --key large.bin --query ETag --output text 2>&1)" ||
    abort "read large.bin's metadata — $etag"
  case "$etag" in
    *-2\"|*-2) pass "large.bin was stored as a two-part multipart upload" ;;
    *) abort "large.bin was not stored as a multipart upload — ETag $etag" ;;
  esac

  local file
  for file in small.bin large.bin; do
    attempt "download $file" aws s3 cp "s3://$NAME/$file" "$STATE/$file.downloaded"
    if [ "$(sha256 "$STATE/$file")" = "$(sha256 "$STATE/$file.downloaded")" ]; then
      pass "$file matches what was uploaded"
    else
      abort "compare $file — the downloaded bytes differ from the uploaded ones"
    fi
  done
  rm -f "$STATE"/*.bin "$STATE"/*.downloaded
}

# attempt — run one operation once; the first failure ends the run.
attempt() {
  local op="$1" err
  shift
  if err="$("$@" 2>&1 >/dev/null)"; then
    pass "$op"
  else
    abort "$op — $(tail -3 <<<"$err" | tr '\n' ' ')"
  fi
}

# retry — run one cleanup operation, retrying three times ten seconds apart.
# A delete that still fails ends cleanup with the leftovers recorded.
retry() {
  local op="$1" err n
  shift
  for n in 1 2 3 4; do
    if err="$("$@" 2>&1 >/dev/null)"; then
      pass "$op"
      return
    fi
    echo "    attempt $n: $(tail -3 <<<"$err" | tr '\n' ' ')"
    [ "$n" -eq 4 ] || sleep 10
  done
  abort "$op — failed 4 times"
}

bucket_exists() {
  local err
  if err="$(aws s3api head-bucket --bucket "$NAME" 2>&1)"; then
    return 0
  fi
  # Anything other than a clear "not there" counts as present, so a network
  # error leads to retried deletes rather than to deleting the tenant early.
  ! grep -qE '\(404\)|Not Found|NoSuchBucket' <<<"$err"
}

# hilt_call — one Tenant API request. Sets HILT_STATUS and leaves the body in
# $RESPONSE.
hilt_call() {
  local method="$1" path="$2" body="${3-}"
  local args=(--silent --show-error --max-time 30 --request "$method"
    --header "@$AUTH_HEADER" --output "$RESPONSE" --write-out '%{http_code}')
  [ -z "$body" ] || args+=(--header 'Content-Type: application/json' --data "$body")
  : >"$RESPONSE"
  HILT_STATUS="$(curl "${args[@]}" "$HILT_URL$path" 2>"$RESPONSE.err" || true)"
}

# hilt_error — describe a failed Tenant API request. Only error bodies get here,
# and Hilt's carry a message, never a key.
hilt_error() {
  if [ "$HILT_STATUS" = 000 ] || [ -z "$HILT_STATUS" ]; then
    echo "no response from $HILT_URL: $(tr '\n' ' ' <"$RESPONSE.err")"
  else
    echo "HTTP $HILT_STATUS: $(jq -r '.message // .error // empty' "$RESPONSE" 2>/dev/null || head -c 300 "$RESPONSE")"
  fi
}

# hilt_expect — a Tenant API request that succeeds on any of the listed
# statuses. For retry, which reads only the exit code and stderr.
hilt_expect() {
  local method="$1" path="$2" body="$3" status
  shift 3
  hilt_call "$method" "$path" "$body"
  for status in "$@"; do
    [ "$HILT_STATUS" != "$status" ] || return 0
  done
  hilt_error >&2
  return 1
}

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

main
