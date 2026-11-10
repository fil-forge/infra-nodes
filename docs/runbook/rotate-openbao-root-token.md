# Rotate the root token of an appliance's OpenBao

Use this procedure when the root token of a node's own OpenBao has leaked: it was pasted into a
chat, a log, a ticket or a shell history. The token never expires and administers every secret the
node holds, for whoever can reach OpenBao's API. That is root on the host, through `docker exec`,
and code running in the Ingot container, which runs as root and mounts OpenBao's unix socket from
`/run/fil-one/bao`.

The rotation mints a replacement under the leaked token, stores it in 1Password, revokes the leaked
one and takes a snapshot. The node keeps serving throughout. Nothing on the node uses the root
token: deploys, reconcile passes and snapshots run as the host token in `/etc/fil-one/bao-token`,
and Ingot holds a region-key token of its own. Both are orphans, so revoking the root token leaves
them alone; step 2 checks that on the live tokens.

Every snapshot taken before the rotation still holds the leaked token, and the backup bucket keeps
each one for 35 days.
[Snapshots taken before the rotation](#snapshots-taken-before-the-rotation) covers what that means
for 1Password and for a later restore.

## Before you start

- **A terminal outside any recorded session.** Step 4 prints the new token once. Claude sessions
  can read the Claude app's Terminal panel, and a terminal multiplexer or `script` may log it.
- **Write access to the node's 1Password items.**
- **On a node that takes backups, the `ReadOnlyAccess` SSO role in the stage's central account**,
  to list the backup bucket. Staging's is `forge-nodes-backups-staging-654654381893` in
  `us-east-2`; [Restore the appliance's OpenBao from a snapshot](restore-openbao-from-snapshot.md#this-nodes-values)
  says where to find another node's.

`bao operator generate-root` with the recovery key also produces a root token, and is the way back
when no valid root token exists. This procedure does not use it: it brings the recovery key, which
has not leaked, out of 1Password and onto the node, and gains nothing while the leaked token still
works. Read `bao operator generate-root -h` on the node before using it, because its defaults
changed across OpenBao 2.x.

## 1. Open a root Bash shell on the node

On staging, from a laptop:

```sh
ssh -t root@23.83.66.244 'cd /root/fil-one/infra-nodes && exec bash'
```

Root's login shell there is Fish; the command starts Bash in the checkout. On dev, open a shell with
`scripts/operator/ssm-session.sh dev`, run `sudo -i`, then `cd /opt/fil-one/infra-nodes && bash`.

Load the OpenBao helpers and define `token_facts`, which prints a token's properties without its
`id`. The `id` is the token itself, so a plain `bao token lookup` prints the secret. Defining the
function prints nothing; step 2 calls it with a token.

```sh
. scripts/host/lib.sh

token_facts() {
  [ -n "${1:-}" ] || { echo "usage: token_facts <token>" >&2; return 2; }
  local lookup
  lookup="$(BAO_TOKEN="$1" bao_in filone-openbao token lookup -format=json)" || return 1
  printf '%s' "$lookup" | python3 -c 'import json, sys
d = json.load(sys.stdin)["data"]
for key in ("display_name", "accessor", "policies", "orphan", "ttl", "path"):
    print(f"  {key}: {d.get(key)}")'
}
```

Every command below uses `bao_in`, which takes the container's name and hands `BAO_TOKEN` to
`docker exec` by name, so no token appears in an argv. `lib.sh` also defines `die`, which exits
the shell, so call nothing from it except `bao_in` and `bao_rejects_token`.

## 2. Enter the leaked token and check the node's tokens

```sh
read -rsp "current root token (1Password): " old_token; echo
token_facts "$old_token"
```

`read -s` keeps the value off the screen, out of Bash history and out of every argv. Expect:

```text
  display_name: root
  accessor: <old accessor>
  policies: ['root']
  orphan: True
  ttl: 0
  path: auth/token/root
```

Write the accessor down. `Code: 403. Errors: * permission denied` means the token is not valid in
the live store, for example because the store was restored from a snapshot taken after an earlier
rotation. Find the right one before going on.

Check that the host token and Ingot's region-key token are orphans:

```sh
token_facts "$(cat /etc/fil-one/bao-token)"

ingot_token="$(BAO_TOKEN="$(cat /etc/fil-one/bao-token)" bao_in filone-openbao \
  kv get -mount=filone -field=regionkey_token ingot)"
token_facts "$ingot_token"; unset ingot_token
```

Expect `policies: ['default', 'filone-host']` for the first and
`policies: ['default', 'ingot-regionkey']` for the second, both with `orphan: True` and a `ttl` of
at most 72 hours. If either shows `orphan: False`, stop: revoking the root token would revoke that
token as well, and with it the node's deploys or Ingot's writes.

Count the tokens in the store, to compare after the revoke:

```sh
BAO_TOKEN="$old_token" bao_in filone-openbao list -format=json auth/token/accessors |
  python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'
```

## 3. Mint the replacement

```sh
new_token="$(BAO_TOKEN="$old_token" bao_in filone-openbao token create \
  -policy=root -orphan -display-name="root-rotated-$(date -u +%Y-%m-%d)" -field=token)"
token_facts "$new_token"
```

Expect `display_name: token-root-rotated-<date>`, `policies: ['root']`, `orphan: True` and
`ttl: 0`. Write the accessor down for the 1Password note in step 4. An accessor names a token
without being a secret: it tells which root token a store's audit entries came from, and
`bao token revoke -accessor <accessor>` revokes the token without anyone pasting it. To read it
again later, under the token from 1Password:

```sh
read -rsp "root token (1Password): " root_token; echo
BAO_TOKEN="$root_token" bao_in filone-openbao token lookup -format=json |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["accessor"])'
unset root_token
```

`bao token lookup` takes no `-field` flag, hence the JSON.

`-orphan` is what keeps the new token alive in step 5. Without it, the new token is a child of the
leaked one and the revoke takes both. OpenBao gives a root-policy token created without `-ttl` no
expiry, the same as the token `bao operator init` printed.

## 4. Store the new token in 1Password

Make two changes in 1Password before anything is revoked:

- **The node's existing root-token item**, the one the provisioning and restore scripts mean by
  "the root token from 1Password": replace the token with the new one, and replace its notes with
  the first note below.
- **A new item for the leaked token**, titled for example "OpenBao root token, staging
  eu-central-3, snapshots before 2026-11-11 only", with the second note below.

Each root-token item opens a range of snapshot keys, and the notes say which. The placeholders:

- `<timestamp>` is the key of the first snapshot after this rotation, which step 6 prints. Write it
  in then.
- `<start>` is where the leaked token's range begins. On the first rotation that is
  `the first snapshot`. After an earlier rotation it is the key that rotation's step 6 printed,
  which the existing item's note names.
- The delete date is 36 days after the rotation: the bucket locks a snapshot for 35 days and
  deletes it a day later.

```text
Root token of the local OpenBao on <stage>/<region>, minted <date> with
`bao token create -policy=root -orphan` to replace a leaked root token.
Display name: token-root-rotated-<date>
Accessor: <new accessor>

Valid in the live store and in every raft snapshot from
s3://<bucket>/<region>/openbao/<timestamp>.snap on. An older snapshot takes
the root token of the item whose range holds its key, starting with
"<old item's title>".
```

```text
Previous root token of the local OpenBao on <stage>/<region>. It leaked and
was REVOKED on the live node on <date>. Do not use it on the live node.
Accessor: <old accessor>

Valid only in a store restored from a raft snapshot with a key under
s3://<bucket>/<region>/openbao/ from <start> up to, not including,
<timestamp>.snap.
- verify-openbao-snapshot.sh on such a snapshot takes this token. Its
  container is thrown away, so nothing needs revoking afterwards.
- A restore from such a snapshot brings this token back. Give it to
  provision-platform.sh, then rotate again with
  docs/runbook/rotate-openbao-root-token.md, which revokes it a second time.

Delete this item once the oldest key under s3://<bucket>/<region>/openbao/
is <timestamp>.snap or later, on or after <date + 36 days>.
```

Print the new token, copy it into the existing item, then clear the screen and the scrollback:

```sh
printf '%s\n' "$new_token"
```

```sh
clear; printf '\e[3J'
```

If the local terminal keeps its own scrollback, clear that too (Cmd+K in Terminal and iTerm2).

Paste the token back from 1Password, to prove the item holds the value OpenBao issued:

```sh
read -rsp "new root token, from 1Password: " check_token; echo
[ "$check_token" = "$new_token" ] && echo "1Password holds the new token" ||
  echo "MISMATCH: fix the 1Password item before revoking"
unset check_token
```

Central's OpenBao holds a second copy of the root token and the recovery key. Replace it as well,
from infra-central, with the new token and the unchanged recovery key from 1Password:

```sh
make store-appliance-root-credentials STAGE=<stage> REGION=<region>
```

Central keeps the earlier versions, so the leaked token stays readable there for a restore from a
snapshot taken before the rotation.

## 5. Revoke the leaked token

```sh
BAO_TOKEN="$old_token" bao_in filone-openbao token revoke -self
```

It prints `Success! Revoked token (if it existed)`. Check both tokens:

```sh
bao_rejects_token filone-openbao "$old_token"; echo "old token: $?"
bao_rejects_token filone-openbao "$new_token"; echo "new token: $?"
```

`0` means rejected, `1` accepted, and `2` that OpenBao gave no answer about the token, for example
because it is sealed. Expect `old token: 0` and `new token: 1`. The new token being accepted shows
that `-orphan` took.

Count the tokens again, under the new token:

```sh
BAO_TOKEN="$new_token" bao_in filone-openbao list -format=json auth/token/accessors |
  python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'
```

Expect the count from step 2: one token minted, one revoked. A lower count means the leaked token
had children, which the revoke took with it.

Run a reconcile pass. It renews the host token and Ingot's region-key token, so it fails if the
revoke reached either:

```sh
systemctl start filone-reconcile.service && echo "reconcile passed"
```

The unit is `Type=oneshot`, so `start` waits for the pass and fails with it.
`journalctl -u filone-reconcile.service -n 50 --no-pager` says why.

## 6. Take a snapshot and clean up

Skip the snapshot on a node that takes no backups, such as dev.

A token minted by hand leaves no snapshot marker, so nothing snapshots the rotation until the daily
run. Take one now:

```sh
scripts/host/snapshot-openbao.sh
```

It prints `uploading <n> bytes to s3://<bucket>/<region>/openbao/<timestamp>.snap`. Fill
`<timestamp>` into both 1Password notes from step 4: snapshots with an earlier key may hold the
leaked token, and this one and every later one hold only the new one.

Restore drills and restores leave copies of earlier stores in the node's control directory, and the
leaked token works in every one of them. A drill's `rollback.sh` would put one back as the live
store. Run the cleanup script, which looks in the directory the node's `node.env` names
(`/mnt/data/fil-one/control` on staging):

```sh
scripts/host/openbao-restore-cleanup.sh
```

It prints `No restore leftovers on <node>.` when there are none. Otherwise it lists them, together
with any seal or host tokens a restore moved aside, and deletes them once you type the node's name.

Then clear the tokens from the shell and leave:

```sh
unset old_token new_token
exit
```

## Snapshots taken before the rotation

Every snapshot with a key before step 6's `<timestamp>` holds the leaked token. The bucket locks
each snapshot for 35 days and deletes it a day later, so the last of them is gone about 36 days
after the rotation. A snapshot unseals only through central's `appliance-unseal-<region>` transit
key, so the leaked token in it is worth nothing to someone who cannot reach central.

A rotation inside those 36 days of an earlier one leaves three ranges of keys, each opened by a
different root token, and a third rotation leaves four. The 1Password notes from step 4 name each
item's range. To find the token a snapshot takes, pick the item whose range holds its key.

**Deleting the leaked token's item.** Delete it once the oldest key in the bucket is `<timestamp>`
or later. From a laptop signed in to the stage's central account, on staging:

```sh
aws s3api list-objects-v2 --no-cli-pager --region us-east-2 \
  --bucket forge-nodes-backups-staging-654654381893 --prefix eu-central-3/openbao/ \
  --query 'sort_by(Contents, &Key)[0].Key' --output text
```

It prints one key, such as `eu-central-3/openbao/20261109T162837Z.snap`. `--no-cli-pager` keeps
AWS CLI v2 from handing that line to `less`, which can clear it off the screen on exit.

**Checking a snapshot.** `verify-openbao-snapshot.sh` asks for the root token the snapshot's store
accepts: the token of the item whose range holds the snapshot's key. Its container is thrown away on
exit, so nothing needs revoking afterwards.

**Restoring from a snapshot before the rotation.** The restored store accepts the token of the item
whose range holds the snapshot's key, and has no record of any later one. `provision-platform.sh`
asks for the root token once or twice; give it that token. Once the node checks out, rotate again
with this procedure: it mints a new token, revokes the restored one a second time and takes a
snapshot. Keep the item of the token that was current before the restore, with its range ending at
the restore, until those snapshots expire as well.
