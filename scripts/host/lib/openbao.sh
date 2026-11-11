#!/usr/bin/env bash
# The node's own OpenBao: starting it, running its CLI, the tokens it holds, the
# secrets it stores and the snapshots taken of it.
#
# Sourced by lib.sh, never on its own. The functions here use lib.sh's
# variables and helpers, such as die, write_secret_file and compose_platform,
# which are all defined by the time any of them is called.

# shellcheck shell=bash
# SC2154: filone_init reads /etc/fil-one/node.conf and the node's node.env, so
# the variables from both are assigned at run time, in files no static check
# can see.
# shellcheck disable=SC2154

# --- Running OpenBao -------------------------------------------------------

# Run the bao CLI inside the OpenBao container. The container publishes no port
# and its listener is on loopback, so `docker exec` is the only way in and the
# API is unreachable from anywhere but this box.
bao() {
  local token
  token="$(cat "$FILONE_BAO_TOKEN_FILE" 2>/dev/null || true)"
  [ -n "${token:-${BAO_TOKEN:-}}" ] || die "no OpenBao token; run provision-platform.sh first"

  docker exec -i \
    -e "BAO_ADDR=http://127.0.0.1:8200" \
    -e "BAO_TOKEN=${BAO_TOKEN:-$token}" \
    "$FILONE_BAO_CONTAINER" bao "$@"
}

# Put the seal token where compose can interpolate it, and make sure the file
# holding the rest exists. Compose refuses to start when a named --env-file is
# missing, and on a first run the rest cannot exist yet: it is read out of the
# OpenBao this token is about to unseal.
write_openbao_env() {
  [ -r "$FILONE_SEAL_TOKEN_FILE" ] ||
    die "no seal token at $FILONE_SEAL_TOKEN_FILE; run provision-platform.sh"

  # write_secret_file returns 1 for "unchanged", which is not a failure. It
  # calls die on an actual write failure, so nothing here has to inspect the
  # status: a `|| true` would also disable errexit inside the function and let
  # a failed mv leave a stale openbao.env behind.
  write_secret_file "$FILONE_SECRETS_DIR/openbao.env" \
    "SEAL_TOKEN=$(cat "$FILONE_SEAL_TOKEN_FILE")
" || [ "$?" -eq 1 ]

  [ -f "$FILONE_SECRETS_DIR/platform.env" ] ||
    install -m 0400 /dev/null "$FILONE_SECRETS_DIR/platform.env"
}

# Where the central OpenBao is, read from the seal stanza in the node's bao.hcl.
# That stanza is the only statement of the address, so nothing here keeps a
# second copy that can disagree with the one OpenBao actually seals against.
#
# Scoped to the stanza rather than to the whole file. `address` appears in the
# listener block too, and that block comes first, so the first match in the file
# is this node's own loopback.
central_seal_addr() {
  local config="$FILONE_NODE_DIR/platform/config/openbao/bao.hcl" value
  value="$(awk '
    /^seal[[:space:]]+"/ { inside = 1; next }
    inside && /^}/       { inside = 0 }
    inside && $1 == "address" && match($0, /"[^"]*"/) {
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  ' "$config")"
  [ -n "$value" ] || die "no address in the seal stanza of $config"
  printf '%s' "$value"
}

# Exchange a wrapping token minted at central for what it wraps, and print the
# response body. The second argument is the mint flag that replaces the
# credential, which the failure messages tell the operator to ask for.
#
# On a 200 the body holds the credential, so callers keep it in a variable and
# never print it. They also call this through a command substitution, where die
# ends only the subshell, so each call is followed by `|| exit 1`.
unwrap_at_central() {
  local wrapping_token="$1" reissue_flag="$2" central curl_status=0 response status body
  central="$(central_seal_addr)"

  # curl puts --header values in its own argv, where anything on the host that
  # can read /proc can take the token while the request is in flight, so the
  # header goes in on stdin. printf is a shell builtin and never gets an argv of
  # its own. The exit code is kept because it is what says whether the request
  # ever left, which an `if !` would collapse to 1.
  response="$(printf 'X-Vault-Token: %s\n' "$wrapping_token" |
    curl -sS --max-time 30 -w '\n%{http_code}' --header @- \
      --request POST "$central/v1/sys/wrapping/unwrap")" || curl_status=$?

  case "$curl_status" in
    0) ;;
    6 | 7)
      die "could not reach the central OpenBao at $central (curl $curl_status).
       Nothing left this node, so the wrapping token is unspent: fix the route to
       central and re-run with the same token." ;;
    *)
      die "the exchange with $central broke off mid-flight (curl $curl_status), so
       whether central spent the wrapping token is unknown, and so is whether the
       credential it unwrapped went anywhere. Do not paste this token again: if it
       was spent, the next attempt is refused and that refusal says nothing about
       who spent it. Re-mint at central with MINT_ARGS=$reissue_flag, which
       replaces the credential, and claim the token that comes back." ;;
  esac

  status="$(printf '%s' "$response" | tail -1)"
  body="$(printf '%s' "$response" | sed '$d')"

  case "$status" in
    200) ;;
    400 | 403 | 404)
      die "central refused the wrapping token (HTTP $status): $body
       A wrapping token can be spent once and expires 24 hours after it is minted,
       so this is a token that has already been exchanged or one that has run out.
       An earlier run of this script that broke off mid-flight spends it the same
       way; failing that, somebody who could read the channel it was delivered on
       spent it. Either way this is not a retry: re-mint at central with
       MINT_ARGS=$reissue_flag, which replaces the credential that was taken." ;;
    *)
      die "the exchange with $central failed with HTTP $status: $body" ;;
  esac

  printf '%s' "$body"
}

bao_is_unsealed() {
  # `bao status` exits 0 unsealed, 2 sealed, 1 unreachable, and needs no token.
  docker exec -i -e "BAO_ADDR=http://127.0.0.1:8200" "$FILONE_BAO_CONTAINER" \
    bao status >/dev/null 2>&1
}

# Ask the operator for the wrapping token central minted for this node's seal
# token, exchange it, and store the seal token 0400 root. The caller says where
# the wrapping token comes from before calling this.
#
# Central mints the seal token wrapped, so an operator carries a single-use
# wrapping token here and the seal token itself stays inside the central OpenBao
# until this node claims it. Nothing but this exchange ever sees the credential,
# and because the exchange can happen once, a token central refuses is one that
# has already been spent, whether by somebody else or by a run that broke off
# before it stored anything.
claim_seal_token() {
  local wrapping_token body seal_token
  read -rsp "unseal-token wrapping token: " wrapping_token
  echo
  [ -n "$wrapping_token" ] || die "no wrapping token given"

  # On success this holds the seal token, so it is never printed.
  body="$(unwrap_at_central "$wrapping_token" --reissue-unseal-token)" || exit 1
  unset wrapping_token

  # Assert the one path the credential comes back on rather than searching for
  # it. A response shaped any other way is worth stopping on: the alternative is
  # storing an empty file and finding out at the unseal.
  seal_token="$(printf '%s' "$body" | python3 -c '
import json, sys

token = (json.load(sys.stdin).get("auth") or {}).get("client_token")
if not token:
    sys.exit("the unwrapped response carries no auth.client_token")
print(token)
')" || die "central returned something other than a wrapped token; nothing was stored"
  unset body

  install -m 0400 /dev/null "$FILONE_SEAL_TOKEN_FILE"
  printf '%s\n' "$seal_token" >"$FILONE_SEAL_TOKEN_FILE"
  unset seal_token
  echo "  stored in $FILONE_SEAL_TOKEN_FILE"
}

# Start the OpenBao container with the seal token on disk, and wait until it
# answers.
start_openbao() {
  write_openbao_env
  compose_platform up -d openbao
  wait_for_bao "$FILONE_BAO_CONTAINER"
}

# Wait up to a minute for the OpenBao in a container to answer. An
# uninitialised OpenBao reports sealed, so this waits for it to answer at all
# rather than for it to be unsealed. One that never answers is left for
# bao_is_initialised to report.
wait_for_bao() {
  local container="$1" status
  for _ in $(seq 1 30); do
    docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 "$container" \
      bao status >/dev/null 2>&1 && break
    status=$?
    [ "$status" -eq 2 ] && break
    sleep 2
  done
}

# Whether the OpenBao in a container, the node's own by default, has been
# initialised. Dies when it cannot tell, because both answers lead somewhere
# irreversible: one to an init, the other past it.
bao_is_initialised() {
  local container="${1:-$FILONE_BAO_CONTAINER}" status_json initialised

  # `bao status` exits 2 on a sealed server, which an uninitialised one is, so
  # the read and the parse are separate statements. Piping the two together
  # under pipefail hands the fallback a non-zero pipeline even when the parse
  # succeeded, and the variable ends up holding the answer and the word unknown.
  status_json="$(docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 "$container" \
    bao status -format=json 2>/dev/null || true)"
  initialised="$(printf '%s' "$status_json" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["initialized"])' 2>/dev/null || echo unknown)"

  case "$initialised" in
    True) return 0 ;;
    False) return 1 ;;
    *) die "cannot tell whether OpenBao is initialised; check 'docker logs $container'" ;;
  esac
}

# --- Tokens ----------------------------------------------------------------

# Renew the node's local host token. It is periodic, which means it renews
# forever but only for as long as something calls renew, and nothing on the node
# holds it long enough to: every use is a one-shot `docker exec ... bao` that
# exits when the command does, leaving no client behind to keep a lease alive.
# The seal token works the other way, and the local OpenBao renews that one
# itself through the lifetime watcher on its transit seal.
#
# So this runs on every reconcile pass, including a pass with nothing to deploy.
# Let the period lapse and the next deploy stops at its first secret read.
renew_bao_token() {
  bao token renew >/dev/null ||
    die "could not renew the local OpenBao host token"
}

# Renew the token Ingot holds for the region wrap key. Periodic like the deploy
# token, and renewed on the same schedule and for the same reason: Ingot's own
# lifetime watcher is not shipped yet, so nothing inside the running process
# keeps its lease alive.
#
# The read and the renewal use different tokens on purpose. bao() prefers
# BAO_TOKEN over the host token file, so the assignment below makes `bao token
# renew` act on the region token, while bao_get above it still runs under the
# host token that is allowed to read the secret. Written as two statements
# rather than one prefixed command: a die inside the substitution of a
# `BAO_TOKEN="$(bao_get ...)" bao ...` prefix is swallowed, BAO_TOKEN lands
# empty, and the renewal silently extends the host token instead.
renew_ingot_regionkey_token() {
  local token
  bao_has ingot regionkey_token ||
    die "OpenBao has no token for the region wrap key. Run
       scripts/host/provision-regionkey.sh; without it Ingot cannot encrypt or
       decrypt any object."
  token="$(bao_get ingot regionkey_token)"

  BAO_TOKEN="$token" bao token renew >/dev/null ||
    die "could not renew Ingot's region-key token. If it has already lapsed,
       scripts/host/provision-regionkey.sh mints a replacement."
}

# Create the KV mount, the filone-host policy and the token the node's own
# automation runs as: every deploy, every reconcile pass and the OpenBao
# snapshot job. Called by provision-platform.sh on a new node and by
# provision-host-token.sh on one that holds an older token; both run it under
# the root token, which is what writing a policy and minting an orphan need.
#
# Minted on every run, like the region-key token, because this is also the
# rotation path. The new token is in place before the old one is revoked, so a
# reconcile pass that starts in between reads one or the other and both work.
provision_host_token() {
  bao secrets enable -path="$FILONE_BAO_MOUNT" -version=2 kv >/dev/null 2>&1 ||
    echo "  kv mount $FILONE_BAO_MOUNT already enabled"

  # What the node's automation does and nothing else. Deploys read and write
  # the node's own secrets, keygen and the provisioning scripts add to them, and
  # the snapshot job reads raft snapshots to push off the host. It cannot delete
  # a secret, restore a snapshot, or touch a policy, a mount or the transit
  # engine, so everything that changes OpenBao itself still needs the root token.
  # A host job that needs more extends this policy rather than getting a token
  # of its own.
  bao policy write filone-host - <<POLICY >/dev/null
path "$FILONE_BAO_MOUNT/data/*" {
  capabilities = ["create", "read", "update", "patch"]
}
path "$FILONE_BAO_MOUNT/metadata/*" {
  capabilities = ["read", "list"]
}
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
POLICY

  # Orphan, so revoking the root token later does not take the node's deploys
  # with it. Periodic, so it renews forever; every reconcile pass renews it,
  # which is every five minutes.
  local token old_token="" tmp
  token="$(bao token create -policy=filone-host -orphan -period=72h -field=token)" ||
    die "could not create the filone-host token"
  [ -n "$token" ] || die "OpenBao returned an empty filone-host token"

  [ -r "$FILONE_BAO_TOKEN_FILE" ] && old_token="$(cat "$FILONE_BAO_TOKEN_FILE")"

  install -d -m 0755 "$(dirname "$FILONE_BAO_TOKEN_FILE")"
  tmp="$(mktemp "$FILONE_BAO_TOKEN_FILE.XXXXXX")"
  chmod 0400 "$tmp"
  printf '%s\n' "$token" >"$tmp"
  mv "$tmp" "$FILONE_BAO_TOKEN_FILE"
  unset token
  echo "  filone-host token stored in $FILONE_BAO_TOKEN_FILE"

  # The old token revokes itself, through revoke-self in OpenBao's default
  # policy, so it never travels in an argv. A token that has already lapsed
  # cannot, and needs nothing.
  if [ -n "$old_token" ]; then
    if BAO_TOKEN="$old_token" bao token revoke -self >/dev/null 2>&1; then
      echo "  previous host token revoked"
    else
      echo "  previous host token could not revoke itself; it has most likely lapsed already"
    fi
  fi
  unset old_token

  # The policy the host token held before it was named for the whole host.
  # Nothing references it once the token above is revoked. A new node never had
  # it.
  if bao policy read filone-deploy >/dev/null 2>&1; then
    bao policy delete filone-deploy >/dev/null ||
      die "could not delete the filone-deploy policy"
    echo "  filone-deploy policy deleted"
  fi

  mark_openbao_written
}

# Create the transit engine, the region key, the policy that reaches it and the
# token Ingot holds. Called by provision-platform.sh on a new node and by
# provision-regionkey.sh on one that predates the key; both run it under the
# root token, which is what enabling an engine and writing a policy need.
provision_regionkey() {
  bao secrets enable -path=transit transit >/dev/null 2>&1 ||
    echo "  transit engine already enabled"

  # aes256-gcm96 with derived keys: Ingot passes each object's own context to
  # encrypt and decrypt, so one region key produces a distinct key per object
  # and the ciphertexts cannot be moved between them.
  if bao read "transit/keys/$FILONE_REGIONKEY_NAME" >/dev/null 2>&1; then
    echo "  transit key $FILONE_REGIONKEY_NAME already exists"
  else
    bao write "transit/keys/$FILONE_REGIONKEY_NAME" type=aes256-gcm96 derived=true >/dev/null ||
      die "could not create transit/keys/$FILONE_REGIONKEY_NAME"
    echo "  transit key $FILONE_REGIONKEY_NAME created"
  fi

  # Wrap and unwrap under this one key, and nothing else. Reading the key
  # material is not on the list, so a copy of the token lifted out of Ingot's
  # config wraps and unwraps against this node's OpenBao while it is running and
  # is worth nothing once the node is out of service.
  bao policy write ingot-regionkey - <<POLICY >/dev/null
path "transit/encrypt/$FILONE_REGIONKEY_NAME" {
  capabilities = ["update"]
}
path "transit/decrypt/$FILONE_REGIONKEY_NAME" {
  capabilities = ["update"]
}
POLICY

  # No -no-default-policy: renew-self and lookup-self come from `default`, which
  # is how the host token renews as well.
  #
  # Orphan, so revoking the root token later does not take Ingot's writes with
  # it. Periodic, so it renews forever; every reconcile pass renews it, which is
  # every five minutes, because nothing inside the running Ingot keeps its lease
  # alive yet.
  #
  # Minted on every run, unlike everything above it. This script is the path
  # back from a revoked or lapsed token, and a re-run that kept the dead one
  # would report success and leave Ingot unable to write an object.
  local token
  token="$(bao token create -policy=ingot-regionkey -orphan -period=72h -field=token)" ||
    die "could not create the ingot-regionkey token"

  # patch where the path exists, so Ingot's key, DID and hilt proof survive; put
  # where it does not, because patch fails on a missing path and on a new node
  # this runs before keygen creates it. Over stdin either way: on the command
  # line the token would be in the container's argv.
  if bao_path_exists ingot; then
    bao kv patch -mount="$FILONE_BAO_MOUNT" ingot regionkey_token=- <<<"$token" >/dev/null ||
      die "could not write $FILONE_BAO_MOUNT/ingot#regionkey_token"
  else
    bao kv put -mount="$FILONE_BAO_MOUNT" ingot regionkey_token=- <<<"$token" >/dev/null ||
      die "could not create $FILONE_BAO_MOUNT/ingot"
  fi
  unset token
  echo "  ingot#regionkey_token written"
  mark_openbao_written
}

# --- Secrets ---------------------------------------------------------------

# Read one field. Missing paths and missing fields both fail loudly rather than
# rendering an empty string into a config file.
bao_get() {
  local path="$1" field="$2" value
  value="$(bao kv get -mount="$FILONE_BAO_MOUNT" -field="$field" "$path" 2>/dev/null)" ||
    die "OpenBao has no $FILONE_BAO_MOUNT/$path#$field"
  [ -n "$value" ] || die "OpenBao returned an empty value for $FILONE_BAO_MOUNT/$path#$field"
  printf '%s' "$value"
}

bao_has() {
  bao kv get -mount="$FILONE_BAO_MOUNT" -field="$2" "$1" >/dev/null 2>&1
}

bao_path_exists() {
  bao kv get -mount="$FILONE_BAO_MOUNT" "$1" >/dev/null 2>&1
}

# Write one or more field/value pairs, in a single OpenBao write, and only if
# the first field is not already there. Key generation runs on every provision,
# and a second run must not mint a new identity for a node that is already
# registered with central.
#
# The whole group lands or none of it does, because a key and the metadata that
# names it are useless apart. A Piri key written without its DID leaves a node
# that cannot be provisioned and cannot be retried either: the next run finds
# the key, refuses to mint a second identity, and has nothing to derive the DID
# from. The first field is the one that is looked up, so pass the key itself
# first and its metadata after it.
bao_put_if_absent() {
  local path="$1" field="$2"
  shift
  if [ "$#" -lt 2 ] || [ $(( $# % 2 )) -ne 0 ]; then
    die "bao_put_if_absent $path: expected field/value pairs, got $# arguments"
  fi

  if bao_has "$path" "$field"; then
    echo "  $path#$field already set, keeping it"
    return 0
  fi

  bao_write_fields "$path" "$@"
}

# Write one or more field/value pairs unconditionally, overwriting any that are
# already there. For rotating a value bao_put_if_absent would otherwise leave
# alone, such as a delegation whose audience has changed underneath it.
bao_replace_fields() {
  local path="$1"
  shift
  if [ "$#" -lt 2 ] || [ $(( $# % 2 )) -ne 0 ]; then
    die "bao_replace_fields $path: expected field/value pairs, got $# arguments"
  fi

  bao_write_fields "$path" "$@"
}

# The write both functions above share, in a single OpenBao write. The whole
# group lands or none of it does, because a value and the metadata that names
# it are useless apart.
bao_write_fields() {
  local path="$1" fields json
  shift

  json="$(bao_fields_json "$@")" || die "could not encode the fields for $FILONE_BAO_MOUNT/$path"

  # patch adds fields, put replaces the whole data map. Which one is correct
  # depends on whether the path is there at all, so this asks rather than trying
  # patch and falling back: a patch that failed for any other reason would send
  # a put at a populated path and delete every field already on it.
  #
  # The values go in over stdin as one JSON object. On the command line they
  # would be in the container's argv, which every user on the box can read.
  fields="$(bao_field_names "$@")"
  if bao_path_exists "$path"; then
    bao kv patch -mount="$FILONE_BAO_MOUNT" "$path" - <<<"$json" >/dev/null ||
      die "could not add $fields to $FILONE_BAO_MOUNT/$path"
  else
    bao kv put -mount="$FILONE_BAO_MOUNT" "$path" - <<<"$json" >/dev/null ||
      die "could not create $FILONE_BAO_MOUNT/$path"
  fi
  echo "  $path#$fields written"
  mark_openbao_written
}

# Encode field/value pairs as a JSON object. The pairs arrive over stdin, NUL
# separated, so no secret is ever an argument to anything.
bao_fields_json() {
  printf '%s\0' "$@" | python3 -c '
import json, sys

parts = sys.stdin.buffer.read().split(b"\0")[:-1]
names, values = parts[0::2], parts[1::2]
json.dump(dict(zip((n.decode() for n in names), (v.decode() for v in values))), sys.stdout)
'
}

bao_field_names() {
  local names=""
  while [ "$#" -gt 0 ]; do
    names="${names:+$names,}$1"
    shift 2
  done
  printf '%s' "$names"
}

# --- Snapshots -------------------------------------------------------------

# Raft snapshots follow writes. Anything that writes to the node's OpenBao
# leaves this marker, and request_openbao_snapshot turns it into a snapshot at
# the end of the script that wrote. The snapshot job removes it only after an
# upload succeeds and sets it after any run that fails, so a failed snapshot is
# retried on the next reconcile pass rather than waiting for the daily run.
mark_openbao_written() {
  touch "$FILONE_STATE_DIR/openbao-snapshot-pending"
}

# Start a snapshot in the background when something wrote to OpenBao since the
# last one. --no-block, because the caller is a deploy or a provisioning run that
# has no reason to wait on S3. Only where the timer is enabled: that is what
# provision-backups.sh does once the node holds a working backup key, and before
# then there is nothing to upload with.
request_openbao_snapshot() {
  [ -e "$FILONE_STATE_DIR/openbao-snapshot-pending" ] || return 0
  node_takes_backups || return 0
  systemctl is-enabled --quiet "$FILONE_SNAPSHOT_TIMER" 2>/dev/null || return 0

  echo "  OpenBao changed since its last snapshot; starting one"
  systemctl start --no-block "$FILONE_SNAPSHOT_SERVICE" ||
    echo "  WARNING: could not start $FILONE_SNAPSHOT_SERVICE; the next reconcile pass retries"
}

# Stamp an OpenBao snapshot that reached the backup target. The deadman for
# backups, in the same shape as the deploy stamp: a snapshot job that fails, or
# a timer that stops firing, leaves the value to age.
stamp_openbao_snapshot_success() {
  local tmp
  mkdir -p "$FILONE_METRICS_DIR"
  tmp="$(mktemp "$FILONE_METRICS_DIR/.openbao-snapshot.XXXXXX")"
  {
    echo "# HELP openbao_snapshot_last_success_timestamp Unix time of the last OpenBao raft snapshot uploaded to the backup target."
    echo "# TYPE openbao_snapshot_last_success_timestamp gauge"
    echo "openbao_snapshot_last_success_timestamp $(date +%s)"
  } >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$FILONE_METRICS_DIR/openbao-snapshot.prom"
}

# --- Restoring --------------------------------------------------------------

# Run the bao CLI in a given container under the token in BAO_TOKEN, which goes
# in by name so its value never appears in docker's argv. Callers set it for the
# one call: `BAO_TOKEN="$token" bao_in <container> ...`.
bao_in() {
  local container="$1"
  shift
  docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN "$container" bao "$@"
}

# Disable the node's timers and wait for a deploy in flight to finish, so
# nothing resets the checkout, writes to OpenBao or snapshots it while its store
# is replaced. The timers it disabled are left in PAUSED_TIMERS. Nothing
# re-enables them: the operator does, once the node checks out.
pause_node_timers() {
  local timer
  PAUSED_TIMERS=""
  for timer in filone-reconcile.timer "$FILONE_SNAPSHOT_TIMER" filone-seal-token-renew.timer; do
    systemctl is-enabled --quiet "$timer" 2>/dev/null || continue
    systemctl disable --now "$timer" >/dev/null 2>&1 || die "could not disable $timer"
    PAUSED_TIMERS="${PAUSED_TIMERS:+$PAUSED_TIMERS }$timer"
    echo "  disabled $timer"
  done

  # Disabling a timer leaves a run already in flight alone. A snapshot in flight
  # is stopped, since it only reads. A reconcile pass may be part-way through a
  # deploy, so this waits for it on the deploy lock instead.
  systemctl stop "$FILONE_SNAPSHOT_SERVICE" 2>/dev/null || true
  take_deploy_lock
}

# Move the store in $FILONE_CONTROL_DIR/openbao to <destination>, and put an
# empty raft directory with the same owner and mode in its place. The caller
# stops OpenBao first. The destination sits on the same filesystem, so the move
# is a rename and cannot leave half a store behind.
#
# Usage: move_bao_store_aside <destination>
move_bao_store_aside() {
  local destination="$1" raft_dir="$FILONE_CONTROL_DIR/openbao" uid gid mode
  [ ! -e "$destination" ] || die "$destination exists already"
  read -r uid gid mode < <(stat -c '%u %g %a' "$raft_dir")
  mv -T "$raft_dir" "$destination"
  install -d -o "$uid" -g "$gid" -m "$mode" "$raft_dir"
}

# Initialise the empty store in a running OpenBao container, restore a raft
# snapshot over it, and wait until the snapshot's store is the one answering.
# The snapshot file has to be in the container's /openbao/logs.
#
# OpenBao restores only into an initialised, unsealed server and only under a
# root token, so this initialises one that exists for the restore alone. Its
# recovery key and root token are never printed or stored: the restore replaces
# the store they belong to, and from then on the root token in 1Password is the
# valid one.
#
# Usage: restore_bao_snapshot <container> <snapshot file name>
restore_bao_snapshot() {
  local container="$1" snapshot_name="$2" init_json throwaway_root

  init_json="$(docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 "$container" \
    bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)" ||
    die "could not initialise the empty OpenBao in $container"
  throwaway_root="$(printf '%s' "$init_json" | python3 -c '
import json, sys

token = json.load(sys.stdin).get("root_token")
if not token:
    sys.exit("the init response carries no root_token")
print(token)
')" || die "could not read the root token of the store just initialised in $container"
  unset init_json

  wait_for_bao_unsealed "$container" ||
    die "the empty store in $container did not unseal. The seal token cannot reach
       or use central's transit key; 'docker logs $container' says which."

  BAO_TOKEN="$throwaway_root" bao_in "$container" \
    operator raft snapshot restore -force "/openbao/logs/$snapshot_name" >/dev/null ||
    die "OpenBao in $container refused the snapshot $snapshot_name"

  # Unsealed alone does not show the restore took: the store initialised above
  # was unsealed too. That store's root token is unknown to the snapshot's, so
  # an unsealed server that rejects it is serving the snapshot.
  if ! wait_for_snapshot_store "$container" "$throwaway_root"; then
    echo "  $container has not unsealed the restored store yet; restarting it once"
    docker restart "$container" >/dev/null || die "could not restart $container"
    wait_for_snapshot_store "$container" "$throwaway_root" ||
      die "$container took the snapshot but did not unseal it. The snapshot's root key
       is wrapped by central's appliance-unseal-$REGION_LABEL key, so either that
       key's min_decryption_version is now above the version that wrapped it, or
       the seal token cannot use the key. 'docker logs $container' says which."
  fi
  unset throwaway_root
}

# Wait up to a minute for the OpenBao in a container to report unsealed.
wait_for_bao_unsealed() {
  local container="$1"
  for _ in $(seq 1 30); do
    docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 "$container" \
      bao status >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Wait up to a minute for the OpenBao in a container to be unsealed and to
# reject the token of the store it served before the restore.
wait_for_snapshot_store() {
  local container="$1" replaced_token="$2"
  for _ in $(seq 1 30); do
    if docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 "$container" \
      bao status >/dev/null 2>&1 &&
      bao_rejects_token "$container" "$replaced_token"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Whether the OpenBao in a container answers a token with permission denied:
# returns 0 when it does, 1 when it accepts the token, and 2 on any other
# answer, such as a sealed or unreachable server, which says nothing about the
# token.
bao_rejects_token() {
  local container="$1" token="$2" output
  if output="$(BAO_TOKEN="$token" bao_in "$container" token lookup 2>&1)"; then
    return 1
  fi
  [[ "$output" == *"Code: 403"* ]] && return 0
  return 2
}
