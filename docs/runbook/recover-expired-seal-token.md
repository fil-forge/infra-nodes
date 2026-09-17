# Recover from an expired appliance seal token

Use this procedure when the staging appliance's OpenBao seal token has expired
or was revoked. It assumes the node's persistent control volume is still
available and the OpenBao data directory has not been replaced.

Every operative value below is staging's. The dev node takes the same steps
with different ones:

- Reach it with `scripts/operator/ssm-session.sh dev` and `sudo -i`. There is no
  inbound SSH.
- Its checkout is `/opt/fil-one/infra-nodes`.
- Its control and data directories are `/mnt/fil-one/control` and
  `/mnt/fil-one/data` on EBS volumes, so the ZFS commands below do not apply.
- Mint with `STAGE=dev`, `REGION=us-east-9`, the address from
  `tofu -chdir=terraform/envs/dev output -raw public_ip`, and the dev AWS
  credentials.
- Piri and Ingot publish no host ports there, so `scripts/ci/smoke-test.sh dev`
  replaces the loopback health checks.

## Before changing the node

Reach the staging host over SSH as root. The default shell is Fish, so run the
remote commands through Bash:

```sh
ssh -tt root@23.83.66.244 'bash -lc '\''<commands>'\'''
```

Append `2>&1 | tee <unique-log-file>` to the inspection commands if you want a
record of them. Do not log `provision-platform.sh`. On an initialised store it
prints no credentials, but a store that turns out to need initialising prints
the recovery key and the root token, and the log would hold both.

Capture the current state before restarting services:

```sh
zpool status -xv
zpool list -v
zfs list -o name,mountpoint,used,avail
findmnt /mnt/data/fil-one/control
findmnt /mnt/data/fil-one/data
ps -eo state,pid,ppid,comm,wchan:32,args | awk '$1 ~ /^D/'

docker ps -a
docker inspect filone-openbao \
  --format='status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}'
docker logs --since 48h filone-openbao 2>&1 | tail -300
systemctl status filone-reconcile.timer \
  filone-seal-token-renew.timer --no-pager
```

If ZFS reports device errors, blocked processes, or an unhealthy pool, fix the
storage problem first. Do not force-import, destroy, clear, or scrub the pool
until the storage failure is understood. OpenBao and the applications depend on
the control and data filesystems being readable.

## Stop the timers

`filone-reconcile.timer` fires every five minutes and `reconcile.sh` resets the
checkout to `origin/main`. `provision-platform.sh` takes no deploy lock until
the `deploy-platform.sh` it calls at its step 8, so a reconcile pass during the
recovery can change the scripts underneath it. Stopping a timer leaves a run
already in flight alone, so stop the service too:

```sh
systemctl disable --now filone-reconcile.timer filone-seal-token-renew.timer
systemctl stop filone-reconcile.service
```

## Reissue the central credential

Run this from the `infra-central` checkout using the staging AWS credentials:

```sh
make mint-appliance-token \
  STAGE=staging \
  REGION=eu-central-3 \
  NODE_IP=23.83.66.244 \
  TOKEN_ARGS=--reissue
```

The command returns a one-time wrapping token. Pass it only to the
`provision-platform.sh` prompt on the node. Do not put it in a command
argument, shell history, or captured log.

## Stop the applications

```sh
docker stop filone-ingot filone-piri
```

The next step removes paths that are bind-mount sources of these containers,
and `provision-platform.sh` ends by calling `deploy-platform.sh`, which brings
back whatever it stopped before `deploy-apps.sh` has rendered the files again.
With both already down, `deploy-platform.sh` reports them as left running and
`deploy-apps.sh` starts them on a complete set of secrets. A stopped Piri also
has no proof in flight, so the proving gate passes at once.

## Repair volatile secret paths

After a reboot, `/run/fil-one/secrets` is recreated. If Compose was started
while its source files were absent, Docker may have created empty directories
where secret files should be. Remove only those known, empty placeholders:

```bash
set -euo pipefail

for name in openbao.env platform.env apps.env \
  piri.pem piri-owner-wallet.hex piri-base-config.toml \
  ingot.pem ingot-config.yaml hilt-ingot-proof.txt; do
  path="/run/fil-one/secrets/$name"
  if [ -d "$path" ]; then
    if find "$path" -mindepth 1 -print -quit | grep -q .; then
      echo "ERROR: placeholder is not empty: $path" >&2
      exit 1
    fi
    rmdir "$path"
  fi
done
```

Move both expired tokens aside so provisioning claims replacements:

```sh
ts=$(date -u +%Y%m%dT%H%M%SZ)
mv /etc/fil-one/seal-token /etc/fil-one/seal-token.expired-$ts
mv /etc/fil-one/bao-token /etc/fil-one/bao-token.expired-$ts
```

The deploy token goes with it because it is periodic on a 72-hour period and
`deploy-platform.sh` renews it only once OpenBao is unsealed. Past three days
of sealed OpenBao the token is dead while the file is still there, and
`provision-platform.sh` would report `Deploy token already present` and then
fail with 403 at its first secret read. Moving it costs one root-token prompt
on a shorter outage.

## Restore OpenBao and the platform

From the node checkout, run:

```sh
cd /root/fil-one/infra-nodes
scripts/host/provision-platform.sh
```

Enter the wrapping token when prompted. The script then asks for the root token
twice, once for the deploy token and once for the region key; it is in the
operator password manager. Because the OpenBao store is already initialised,
the run reports that the region key already exists, starts OpenBao, regenerates
the volatile environment files, and finishes the platform health check.

Verify OpenBao before starting the applications:

```sh
docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 filone-openbao bao status -format=json
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

The loopback listener in `platform/config/openbao/bao.hcl` sets
`tls_disable = "true"` and the `bao` CLI defaults to `https://127.0.0.1:8200`,
so without `BAO_ADDR` the call dies in the TLS handshake and reads like a
sealed or broken OpenBao.

## Restore the applications and timers

```sh
scripts/host/deploy-apps.sh

systemctl reset-failed filone-reconcile.service
systemctl enable --now filone-reconcile.timer
systemctl enable --now filone-seal-token-renew.timer
systemctl start filone-reconcile.service
```

Check the local endpoints:

```sh
curl --fail --show-error --max-time 15 http://127.0.0.1:15100/readyz
curl --fail --show-error --max-time 15 http://127.0.0.1:15200/health
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Finish from the operator checkout:

```sh
scripts/ci/smoke-test.sh staging
```

The smoke test must pass the Piri readiness, Ingot health, node-status, and
application-revision checks. If the revision check says the deployed commit is
not in the local checkout, fetch the current branch before rerunning it:

```sh
git fetch origin main
scripts/ci/smoke-test.sh staging
```

After recovery, remove the moved token files once they are no longer needed:

```sh
rm -f /etc/fil-one/seal-token.expired-<timestamp> \
  /etc/fil-one/bao-token.expired-<timestamp>
```
