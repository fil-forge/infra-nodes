# Restore the appliance's OpenBao from a snapshot

Use this procedure when an appliance's OpenBao store is lost: the control storage failed,
the raft directory is corrupt, or the host was rebuilt. The node keeps its Piri and Ingot
identities, its central registration and its hilt delegation, because all of them are in the
snapshot. [Re-onboarding after identity loss](../RUNBOOK.md#re-onboarding-after-identity-loss)
applies only when no snapshot restores.

A restore takes the store back to the moment of the snapshot. A node that was down since then wrote
nothing in between, so the newest snapshot loses nothing. Anything written after it is gone,
including a Piri added since: `provision-platform.sh` gives that Piri a new identity, and it is
re-onboarded on its own.

Dev takes no backups, so it has nothing to restore. A node on EC2 takes the same steps through
`scripts/operator/ssm-session.sh <stage>` and `sudo -i` instead of SSH. The scripts on the node read
its paths from its `node.env`, so no command below names them.

## This node's values

The commands run on a laptop take the node's values from shell variables. Set them once per shell:

| Variable | Staging | Where to find it for another node |
|---|---|---|
| `stage` | `staging` | `STAGE` in `nodes/<stage>/<region>/node.env` |
| `region` | `eu-central-3` | `REGION_LABEL` in the same file |
| `node_ip` | `23.83.66.244` | `server_ip` in `terraform/envs/<stage>/<region>/main.tf` |
| `ingot_url` | `https://s3.eu-central-3.staging.filonecontent.com` | `INGOT_PUBLIC_URL` in `node.env` |
| `central_region` | `us-east-2` | the `region` variable of infra-central's `terraform/envs/<stage>/platform` |
| `backup_bucket` | `forge-nodes-backups-staging-654654381893` | `forge-nodes-backups-<stage>-<account id>`, in the stage's central account |

```sh
stage=staging
region=eu-central-3
node_ip=23.83.66.244
ingot_url=https://s3.eu-central-3.staging.filonecontent.com
central_region=us-east-2
backup_bucket=forge-nodes-backups-staging-654654381893
```

The AWS commands below, `make mint-appliance-credentials` among them, run as the
`AdministratorAccess` role in the stage's central account. Export the AWS CLI profile you use for
that role in the same shell, then check that it reaches the account in `backup_bucket`'s name:

```sh
export AWS_PROFILE=<your profile for that role>
export AWS_PAGER=""
aws sts get-caller-identity --query Account --output text
```

An empty `AWS_PAGER` stops the AWS CLI from opening each result in `less`, which would hold up the
piped commands below.

Without a profile, the mint stops at its first Lambda call with `Unable to locate credentials`.

Signed in to the stage's central account, this lists the backup bucket:

```sh
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'forge-nodes-backups-')].Name"
```

## What a restore needs

- **Central's transit key, still decrypting version 1.** `appliance-unseal-<region>` wraps the
  snapshot's root key. Nothing in infra-central raises its `min_decryption_version`, and nobody may
  by hand within the 35 days the bucket keeps a snapshot, because a raised minimum makes every older
  snapshot unrestorable. To check it, run the mint below without `MINT_ARGS`, and if it asks, type
  anything but `mint`. The read-only first round prints `Key versions: latest <n>, decrypts from 1`
  and warns when the minimum is above 1.
- **A live seal token.** The token is a central credential on the node's root disk, outside the
  snapshot. Any live token for the region unseals any snapshot of the region. It lapses 72 hours
  after its last renewal, and it is bound to the node's IP.
- **The root token from 1Password**, the one printed when the node's OpenBao was first initialised.
  The restore brings it back to life.
- **The `AdministratorAccess` SSO role in the stage's central account**, for every AWS command
  below. `ReadOnlyAccess` can read the backup bucket and the Piri DIDs central recorded, but not run
  `make mint-appliance-credentials`, which the key check and a seal-token reissue need: every round
  of the mint invokes central's provision Lambda.

Reach the host over SSH as root. Staging's root shell is Fish, so run remote commands through Bash:

```sh
ssh -tt "root@$node_ip" 'bash -lc '\''<commands>'\'''
```

Commands on the node run from its infra-nodes checkout, `/root/fil-one/infra-nodes` on staging. This
opens Bash there in one step; the `-t` gives Bash the terminal it needs to stay interactive:

```sh
ssh -t "root@$node_ip" 'cd /root/fil-one/infra-nodes && exec bash'
```

## Pick a snapshot

From a laptop signed in to the stage's central account, list the snapshots and take the newest:

```sh
aws s3api list-objects-v2 --region "$central_region" \
  --bucket "$backup_bucket" \
  --prefix "$region/openbao/" \
  --query 'reverse(sort_by(Contents, &Key))[:5].[Key, Size, ETag]' --output table
```

Each key is the UTC time the snapshot was taken. The commands below read the current version of a
key. After a leak of the node's backup key, whoever holds it can put a new version at any key, so
the current version is not trustworthy. Stop there: a restore after a leak reads the last version
written before the leak, by version ID, and that procedure is not written yet, as
[infra-central's backup decision record](https://github.com/fil-forge/infra-central/blob/main/docs/decisions/2026-11-appliance-backup-target.md#locked-for-35-days-then-expired)
says.

## Copy it to the node

Stream the snapshot straight into `/run/fil-one/bao` on the node. That directory is a tmpfs mounted
into the OpenBao container, so the file never touches a disk on the laptop or the host:

```sh
key="$region/openbao/<timestamp>.snap"
aws s3 cp --region "$central_region" "s3://$backup_bucket/$key" - |
  ssh "root@$node_ip" 'install -d -m 0700 /run/fil-one/bao && cat > /run/fil-one/bao/restore.snap'
```

Compare the copy with the object. The node uploads each snapshot in one PUT with a `Content-MD5`
header, so the object's ETag is its MD5:

```sh
aws s3api head-object --region "$central_region" \
  --bucket "$backup_bucket" --key "$key" --query ETag
ssh "root@$node_ip" md5sum /run/fil-one/bao/restore.snap
```

A reboot empties `/run/fil-one/bao`, so copy the snapshot after the host is back up.

## Get a new seal token, if the old one is gone

Skip this when `/etc/fil-one/seal-token` is on the node and the node was down for less than 72
hours. Otherwise, run from the infra-central checkout:

```sh
make mint-appliance-credentials \
  STAGE="$stage" \
  REGION="$region" \
  NODE_IP="$node_ip" \
  MINT_ARGS=--reissue-unseal-token
```

It returns a single-use wrapping token. Pass it only to the prompt of `restore-openbao.sh`, never
on a command line or into a log. The reissue revokes the old seal token, which is the right outcome
for a token that has lapsed or left with a lost host. The token is bound to `NODE_IP`, so a rebuilt
host with a new address passes the new one.

`restore-openbao.sh` asks for the wrapping token only when no seal token is on disk. Move a lapsed
one aside on the node first:

```sh
mv /etc/fil-one/seal-token /etc/fil-one/seal-token.expired-$(date -u +%Y%m%dT%H%M%SZ)
```

## Restore the store

After a reboot, Docker may have left empty directories in `/run/fil-one/secrets` where secret files
belong. Remove them as
[Repair volatile secret paths](recover-expired-unseal-token.md#repair-volatile-secret-paths)
describes.

Then restore:

```sh
scripts/host/restore-openbao.sh /run/fil-one/bao/restore.snap
```

The script refuses a raft directory that still holds a store. When that is the damaged store, run it
with `--move-aside-damaged-store`, which moves the store to `openbao.damaged-<timestamp>` next to
the raft directory once OpenBao has stopped:

```sh
scripts/host/restore-openbao.sh --move-aside-damaged-store /run/fil-one/bao/restore.snap
```

OpenBao 2.6.2 prints `Error properly closing policy file: … file already closed` during the
restore. The line is harmless and mislabelled: the upload closes the snapshot file, and the restore
command then closes it a second time. A failed restore prints `Error installing the snapshot`
instead, and the script stops with `refused the snapshot`.

The script disables the reconcile, snapshot and seal-token-renew timers and leaves them disabled. It
stops the apps and OpenBao and claims the new seal token when none is on disk. Then it initialises a
throwaway store, restores the snapshot over it and waits until the snapshot's store is unsealed.
Last, it moves aside a host token the restored store rejects and deletes the snapshot file. It
prints nothing secret and uploads nothing.

When it fails partway through the restore, it empties the raft directory again, so a second run
starts from the same state. The snapshot file stays in place for that run.

## Bring the node back

```sh
scripts/host/provision-platform.sh
```

On a restored store it skips the seal token and the init, and mints a host token if the restore
moved the old one aside. It finds the backup key in the restored store, checks that the key can
write, uploads a snapshot of the restored store and enables the snapshot timer. It mints a new
region-key token for Ingot and starts the platform. It asks for the root token from 1Password once
or twice.

Three outcomes need attention:

- `[7/9] Generating keys and passwords` prints `identity: did:key:…` for an identity it created.
  That identity was missing from the snapshot. The script then closes with "Next:
  onboarding-request.sh". Re-onboard that Piri as
  [Re-onboarding after identity loss](../RUNBOOK.md#re-onboarding-after-identity-loss) describes.
- `[4/9] Storing the backup key` fails with `InvalidAccessKeyId` when central has deleted the key in
  the snapshot, for example after a leak. Ask central to re-mint with
  `MINT_ARGS=--reissue-backup-key`, then run `scripts/host/provision-backups.sh --replace`.
- Otherwise it closes with "Next: deploy-apps.sh", because the restored store holds hilt's
  delegation. Run that next. The node needs no onboarding.

```sh
scripts/host/deploy-apps.sh
```

## Check the node

Compare each Piri's DID with the one central recorded when it onboarded:

```sh
bash -c '. scripts/host/lib.sh; filone_init; for s in $(piri_services); do echo "$s $(bao_get "$s" did)"; done'
```

```sh
aws ssm get-parameters-by-path --region "$central_region" \
  --path "/forge-central/$stage/appliance/$region/piri" --query 'Parameters[].Value'
```

Then run the smoke test from the operator checkout:

```sh
scripts/ci/smoke-test.sh "$stage/$region"
```

It must print `OK: every check passed`. It does not cover Ingot's region-key token, because Ingot's
`/health` passes with a lapsed one. Read back a known object through `$ingot_url`. A successful
GET shows that Ingot can unwrap
with its new token.

## Re-enable the timers

`provision-platform.sh` has already enabled the snapshot timer. Enable the other two:

```sh
systemctl enable --now filone-reconcile.timer filone-seal-token-renew.timer
systemctl start filone-reconcile.service
```

`systemctl list-timers 'filone-*'` then lists all three timers with their next run.

`openbao_snapshot_last_success_timestamp` advances with the snapshot `provision-platform.sh`
uploaded, so the stale-snapshot alert stays quiet. Once the node checks out, delete the damaged
store and the tokens moved aside during the restore. The script lists what it deletes and asks for
the node's name first. It refuses while OpenBao is not running unsealed, because the damaged store
may then be the only copy left:

```sh
scripts/host/openbao-restore-cleanup.sh
```

## Check a snapshot without downtime

`verify-openbao-snapshot.sh` restores a snapshot into a throwaway OpenBao container next to the live
one, unseals it through central with the node's seal token, and compares each Piri's and Ingot's DID
with the live store. It fails when the snapshot holds a different DID or none for one of them,
because a restore from it would lose that identity. It stops nothing, leaves the timers alone and
removes its container and scratch files when it exits. Stream the snapshot as for a restore, then:

```sh
scripts/host/verify-openbao-snapshot.sh /run/fil-one/bao/verify.snap
rm /run/fil-one/bao/verify.snap
```

It asks for the root token from 1Password, which the restored copy accepts. It prints the same
harmless `Error properly closing policy file` line as a restore.

## Rehearse the restore

Run a drill on staging every quarter, with the variables from
[This node's values](#this-nodes-values) set to staging's. It takes staging out of service for an
hour or two and covers both disasters:

- **Fast restore.** The control storage fails and the node is back within hours, with its seal
  token and host token still live on the root disk. Central mints nothing. This one sets the
  recovery-time budget, since every day without proofs is a proving period that pays nothing.
- **Long outage.** The node is down for 72 hours or more, or its host is rebuilt. Every token has
  lapsed, central reissues the seal token, and the node mints the rest.

`simulate-openbao-loss.sh` puts the node into either state. It refuses to run on a stage other than
staging or dev, asks for the node's name, and moves everything it takes away into
`openbao-drill-<timestamp>/` in the node's control directory without deleting anything. It writes
`rollback.sh` into that directory and prints its path.

### Before the drill

1. Announce the staging downtime.
2. Check that `appliance-unseal-eu-central-3` still decrypts version 1, as
   [What a restore needs](#what-a-restore-needs) describes.
3. Record the newest snapshot's key, as in [Pick a snapshot](#pick-a-snapshot), and each Piri's DID,
   as in [Check the node](#check-the-node).
4. In the Fil One staging console, create a bucket in the **Europe (Amsterdam)** region, which is
   `eu-central-3`. A bucket in another region is served by another gateway and never touches this
   node. One bucket serves every drill, so reuse it when it exists.
5. Create an access key in the same region. A service key needs these permissions on that bucket
   alone, with **Which buckets can this key access?** set to the bucket from step 4:

   - **Write** uploads the marker.
   - **Read** reads it back after each restore.
   - **Delete** removes it at clean-up.

   A personal key has no permissions of its own: it acts as you, and the bucket's policy decides what
   it reaches. Set the key to expire the day after the drill.
6. Write a marker object through Ingot with the key from step 5. The timestamp in its name keeps it
   apart from the markers of earlier drills. The key stays on the laptop:

   ```sh
   marker=drill-marker-$(date -u +%Y%m%dT%H%M%SZ).bin
   marker_bucket=<the bucket from step 4>
   head -c 65536 /dev/urandom > "$marker"
   shasum -a 256 "$marker"
   ```

   Enter the key at a prompt, so the secret stays out of the shell history:

   ```sh
   printf 'Access key ID: '; read -r ingot_key_id
   printf 'Secret access key: '; read -rs ingot_secret; echo
   ```

   Then upload the marker. The two key variables replace `AWS_PROFILE` for this one command only, so
   the central commands in the same shell keep working:

   ```sh
   AWS_ACCESS_KEY_ID="$ingot_key_id" AWS_SECRET_ACCESS_KEY="$ingot_secret" \
     aws s3 cp --region "$region" --endpoint-url "$ingot_url" "$marker" "s3://$marker_bucket/$marker"
   ```

   Each command to Ingot passes `--region "$region"`, because the AWS CLI otherwise signs for the
   profile's region. Ingot refuses that with HTTP 400 and names the right region in the response
   body. The CLI retries an upload in that region, but a download starts with a HeadObject, whose
   response has no body, so it fails with a bare `Bad Request`.

   Keep the checksum and the name `shasum` prints. The read-backs below need `marker`,
   `marker_bucket`, `ingot_key_id` and `ingot_secret`, so set them again in a new shell.

### Check the oldest and the newest snapshot

Without downtime, run [Check a snapshot without downtime](#check-a-snapshot-without-downtime) on the
newest snapshot and on the oldest one the bucket still holds. The oldest shows that every snapshot
in the retention window unseals. It reports as missing any Piri added after it was taken, and then
fails; the unseal it printed before that is what this check is for. The newest exercises the init,
restore and unseal steps of the restore script before the node depends on them, and must pass.

This prints the oldest snapshot's key, then the newest's:

```sh
aws s3api list-objects-v2 --region "$central_region" \
  --bucket "$backup_bucket" \
  --prefix "$region/openbao/" \
  --query '[sort_by(Contents, &Key)[0].Key, sort_by(Contents, &Key)[-1].Key]' --output json
```

JSON output keeps the sort over every page of the listing. With `--output text`, the AWS CLI applies
`--query` to each page of 1,000 keys on its own.

### Fast restore

Time this from the first command to a passing smoke test.

1. `scripts/host/simulate-openbao-loss.sh`. Note the path of the `rollback.sh` it prints.
2. [Copy the newest snapshot to the node](#copy-it-to-the-node).
3. [Restore the store](#restore-the-store) and [bring the node back](#bring-the-node-back). The seal
   token and the host token are still on disk, so nothing asks for a wrapping token, and step 3 of
   `provision-platform.sh` reports the host token present.
4. [Check the node](#check-the-node), and read back the marker object byte for byte:

   ```sh
   AWS_ACCESS_KEY_ID="$ingot_key_id" AWS_SECRET_ACCESS_KEY="$ingot_secret" \
     aws s3 cp --region "$region" --endpoint-url "$ingot_url" "s3://$marker_bucket/$marker" - |
     shasum -a 256
   ```

Leave the timers disabled and go straight on to the long outage, in the same window.

### Long outage

1. `scripts/host/simulate-openbao-loss.sh --lose-root-disk-tokens`. Note the path of the
   `rollback.sh` it prints.
2. [Get a new seal token](#get-a-new-seal-token-if-the-old-one-is-gone).
3. Copy the newest snapshot to the node. It is now the one `provision-platform.sh` uploaded at the
   end of the fast restore.
4. Restore the store and bring the node back. `restore-openbao.sh` asks for the wrapping token, and
   `provision-platform.sh` mints a new host token.
5. Check the node and read back the marker object again.
6. [Re-enable the timers](#re-enable-the-timers).

### Roll back

At any point, the `rollback.sh` a run of `simulate-openbao-loss.sh` wrote puts back the store as it
was when that run started. Run it by the path that run printed. For the long outage, that is the
store the fast restore produced. After a seal-token reissue the script keeps the reissued token,
because the reissue revoked the one moved aside and the reissued one unseals the store as well.

### Clean up

Once the drill passes, delete the drill directories and any token moved aside during a restore,
with the script that cleans up after a real restore:

```sh
scripts/host/openbao-restore-cleanup.sh
```

Then delete the marker object from the laptop:

```sh
AWS_ACCESS_KEY_ID="$ingot_key_id" AWS_SECRET_ACCESS_KEY="$ingot_secret" \
  aws s3 rm --region "$region" --endpoint-url "$ingot_url" "s3://$marker_bucket/$marker"
rm "$marker"
unset ingot_key_id ingot_secret
```
