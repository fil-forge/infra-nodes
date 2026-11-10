# Restore the appliance's OpenBao from a snapshot

Use this procedure when the staging appliance's OpenBao store is lost: the control storage failed,
the raft directory is corrupt, or the host was rebuilt. The node keeps its Piri and Ingot
identities, its central registration and its hilt delegation, because all of them are in the
snapshot. [Re-onboarding after identity loss](../RUNBOOK.md#re-onboarding-after-identity-loss)
applies only when no snapshot restores.

A restore takes the store back to the moment of the snapshot. A node that was down since then wrote
nothing in between, so the newest snapshot loses nothing. Anything written after it is gone,
including a Piri added since: `provision-platform.sh` gives that Piri a new identity, and it is
re-onboarded on its own.

Every value below is staging's. Dev takes no backups, so it has nothing to restore. A node on EC2
takes the same steps through `scripts/operator/ssm-session.sh <stage>` and `sudo -i` instead of
SSH, with its control directory at `/mnt/fil-one/control`.

## What a restore needs

- **Central's transit key, still decrypting version 1.** `appliance-unseal-eu-central-3` wraps the
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
- **The `ReadOnlyAccess` SSO role in the staging account**, to read the backup bucket and the Piri
  DIDs central recorded. `AdministratorAccess` works as well.
- **The `AdministratorAccess` SSO role in the staging account**, for whoever runs
  `make mint-appliance-credentials` in infra-central, for the key check and any seal-token reissue.
  Every round of the mint invokes central's provision Lambda, which `ReadOnlyAccess` cannot do.

Reach the host over SSH as root. Its default shell is Fish, so run remote commands through Bash:

```sh
ssh -tt root@23.83.66.244 'bash -lc '\''<commands>'\'''
```

The checkout is `/root/fil-one/infra-nodes`, and the commands below run from there.

## Pick a snapshot

From a laptop signed in with the staging `ReadOnlyAccess` role, list the snapshots and take the
newest:

```sh
aws s3api list-objects-v2 --region us-east-2 \
  --bucket forge-nodes-backups-staging-654654381893 \
  --prefix eu-central-3/openbao/ \
  --query 'reverse(sort_by(Contents, &Key))[:5].[Key, Size, ETag]' --output table
```

Each key is the UTC time the snapshot was taken. After a leak of the node's backup key, an attacker
may have written later objects or versions under the same prefix, so pick the newest snapshot
written before the leak, by version ID if its key was overwritten.

## Copy it to the node

Stream the snapshot straight into `/run/fil-one/bao` on the node. That directory is a tmpfs mounted
into the OpenBao container, so the file never touches a disk on the laptop or the host:

```sh
key=eu-central-3/openbao/<timestamp>.snap
aws s3 cp --region us-east-2 "s3://forge-nodes-backups-staging-654654381893/$key" - |
  ssh root@23.83.66.244 'install -d -m 0700 /run/fil-one/bao && cat > /run/fil-one/bao/restore.snap'
```

Compare the copy with the object. The node uploads each snapshot in one PUT with a `Content-MD5`
header, so the object's ETag is its MD5:

```sh
aws s3api head-object --region us-east-2 \
  --bucket forge-nodes-backups-staging-654654381893 --key "$key" --query ETag
ssh root@23.83.66.244 md5sum /run/fil-one/bao/restore.snap
```

A reboot empties `/run/fil-one/bao`, so copy the snapshot after the host is back up.

## Get a new seal token, if the old one is gone

Skip this when `/etc/fil-one/seal-token` is on the node and the node was down for less than 72
hours. Otherwise, run from the infra-central checkout, signed in with the staging
`AdministratorAccess` role:

```sh
make mint-appliance-credentials \
  STAGE=staging \
  REGION=eu-central-3 \
  NODE_IP=23.83.66.244 \
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

When the raft directory still holds the damaged store, stop OpenBao and move the directory aside.
The restore script refuses a directory that is not empty, and deletes nothing itself:

```sh
docker stop filone-openbao
mv /mnt/data/fil-one/control/openbao \
  /mnt/data/fil-one/control/openbao.damaged-$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 0700 /mnt/data/fil-one/control/openbao
```

Then restore:

```sh
scripts/host/restore-openbao.sh /run/fil-one/bao/restore.snap
```

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
  That identity was missing from the snapshot. Re-onboard that Piri as
  [Re-onboarding after identity loss](../RUNBOOK.md#re-onboarding-after-identity-loss) describes.
- `[4/9] Storing the backup key` fails with `InvalidAccessKeyId` when central has deleted the key in
  the snapshot, for example after a leak. Ask central to re-mint with
  `MINT_ARGS=--reissue-backup-key`, then run `scripts/host/provision-backups.sh --replace`.
- It closes with "Next: deploy-apps.sh", because the restored store holds hilt's delegation. Run
  that next. The node needs no onboarding.

```sh
scripts/host/deploy-apps.sh
```

## Check the node

Compare each Piri's DID with the one central recorded when it onboarded:

```sh
bash -c '. scripts/host/lib.sh; filone_init; for s in $(piri_services); do echo "$s $(bao_get "$s" did)"; done'
```

```sh
aws ssm get-parameters-by-path --region us-east-2 \
  --path /forge-central/staging/appliance/eu-central-3/piri --query 'Parameters[].Value'
```

Then run the smoke test from the operator checkout:

```sh
scripts/ci/smoke-test.sh staging/eu-central-3
```

It must print `OK: every check passed`. It does not cover Ingot's region-key token, because Ingot's
`/health` passes with a lapsed one. Read back a known object through
`https://s3.eu-central-3.staging.filonecontent.com`. A successful GET shows that Ingot can unwrap
with its new token.

## Re-enable the timers

`provision-platform.sh` has already enabled the snapshot timer. Enable the other two:

```sh
systemctl reset-failed filone-reconcile.service
systemctl enable --now filone-reconcile.timer filone-seal-token-renew.timer
systemctl start filone-reconcile.service
```

`openbao_snapshot_last_success_timestamp` advances with the snapshot `provision-platform.sh`
uploaded, so the stale-snapshot alert stays quiet. Once the node checks out, delete the damaged
store and the tokens moved aside during the restore:

```sh
rm -rf /mnt/data/fil-one/control/openbao.damaged-*
rm -f /etc/fil-one/seal-token.expired-* /etc/fil-one/bao-token.rejected-*
```

## Check a snapshot without downtime

`verify-openbao-snapshot.sh` restores a snapshot into a throwaway OpenBao container next to the live
one, unseals it through central with the node's seal token, and compares each Piri's and Ingot's DID
with the live store. It stops nothing, leaves the timers alone and removes its container and scratch
files when it exits. Stream the snapshot as for a restore, then:

```sh
scripts/host/verify-openbao-snapshot.sh /run/fil-one/bao/verify.snap
rm /run/fil-one/bao/verify.snap
```

It asks for the root token from 1Password, which the restored copy accepts.

## Rehearse the restore

Run a drill on staging every quarter. It takes staging out of service for an hour or two and covers
both disasters:

- **Fast restore.** The control storage fails and the node is back within hours, with its seal
  token and host token still live on the root disk. Central mints nothing. This one sets the
  recovery-time budget, since every day without proofs is a proving period that pays nothing.
- **Long outage.** The node is down for 72 hours or more, or its host is rebuilt. Every token has
  lapsed, central reissues the seal token, and the node mints the rest.

`simulate-openbao-loss.sh` puts the node into either state. It refuses to run on a stage other than
staging or dev, asks for the node's name, and moves everything it takes away into
`/mnt/data/fil-one/control/openbao-drill-<timestamp>/` without deleting anything. It writes
`rollback.sh` into that directory and prints its path.

### Before the drill

1. Announce the staging downtime.
2. Check that `appliance-unseal-eu-central-3` still decrypts version 1, as
   [What a restore needs](#what-a-restore-needs) describes.
3. Record the newest snapshot's key, as in [Pick a snapshot](#pick-a-snapshot), and each Piri's DID,
   as in [Check the node](#check-the-node).
4. Write a marker object through Ingot with an access key from the Fil One staging console. The
   timestamp in its name keeps it apart from the markers of earlier drills. The key stays on the
   laptop:

   ```sh
   marker=drill-marker-$(date -u +%Y%m%dT%H%M%SZ).bin
   head -c 65536 /dev/urandom > "$marker"
   shasum -a 256 "$marker"
   AWS_ACCESS_KEY_ID=YOUR_ACCESS_KEY_HERE AWS_SECRET_ACCESS_KEY=YOUR_SECRET_KEY_HERE \
     aws s3 cp --endpoint-url https://s3.eu-central-3.staging.filonecontent.com \
     "$marker" "s3://<your staging bucket>/$marker"
   ```

   Keep the checksum and the name `shasum` prints. The read-backs below need `marker` set to that
   name, so set it again in a new shell.

### Check the oldest and the newest snapshot

Without downtime, run [Check a snapshot without downtime](#check-a-snapshot-without-downtime) on the
newest snapshot and on the oldest one the bucket still holds. The oldest shows that every snapshot
in the retention window unseals. The newest exercises the init, restore and unseal steps of the
restore script before the node depends on them.

### Fast restore

Time this from the first command to a passing smoke test.

1. `scripts/host/simulate-openbao-loss.sh`. Note the path of the `rollback.sh` it prints.
2. [Copy the newest snapshot to the node](#copy-it-to-the-node).
3. [Restore the store](#restore-the-store) and [bring the node back](#bring-the-node-back). The seal
   token and the host token are still on disk, so nothing asks for a wrapping token, and step 3 of
   `provision-platform.sh` reports the host token present.
4. [Check the node](#check-the-node), and read back the marker object byte for byte:

   ```sh
   AWS_ACCESS_KEY_ID=YOUR_ACCESS_KEY_HERE AWS_SECRET_ACCESS_KEY=YOUR_SECRET_KEY_HERE \
     aws s3 cp --endpoint-url https://s3.eu-central-3.staging.filonecontent.com \
     "s3://<your staging bucket>/$marker" - | shasum -a 256
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
was when that run started:

```sh
/mnt/data/fil-one/control/openbao-drill-<timestamp>/rollback.sh
```

For the long outage, that is the store the fast restore produced. After a seal-token reissue the
script keeps the reissued token, because the reissue revoked the one moved aside and the reissued
one unseals the store as well.

### Clean up

Once the drill passes, delete the drill directories and any token moved aside during a restore. The
script lists what it deletes and asks for the node's name first. It refuses while OpenBao is not
running unsealed, because a drill directory may then hold the only working store:

```sh
scripts/host/openbao-drill-cleanup.sh
```

Then delete the marker object from the laptop:

```sh
AWS_ACCESS_KEY_ID=YOUR_ACCESS_KEY_HERE AWS_SECRET_ACCESS_KEY=YOUR_SECRET_KEY_HERE \
  aws s3 rm --endpoint-url https://s3.eu-central-3.staging.filonecontent.com \
  "s3://<your staging bucket>/$marker"
rm "$marker"
```
