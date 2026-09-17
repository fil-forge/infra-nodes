# Recover from an expired appliance unseal token

_Written by ChatGPT/Codex._

Use this procedure when a regional appliance's OpenBao seal token has expired
or was revoked. The procedure assumes the node's persistent control volume is
still available and the OpenBao data directory has not been replaced.

## Before changing the node

Access the host through its supported operator path. On the staging bare-metal
host, run the remote commands with Bash because the default shell is Fish:

```sh
ssh -tt root@ff 'bash -lc '\''<commands>'\'' 2>&1 | tee <unique-log-file>
```

Do not save raw output from `provision-platform.sh`. A first-time OpenBao
initialisation prints the recovery key and root token. If the store is already
initialised, the procedure reuses the existing root token and does not generate
new recovery credentials.

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

## Repair volatile secret paths

After a reboot, `/run/fil-one/secrets` is recreated. If Compose was started
while its source files were absent, Docker may have created empty directories
where secret files should be. Remove only those known, empty placeholders:

```sh
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

Move the expired token aside so provisioning claims the replacement:

```sh
mv /etc/fil-one/seal-token \
  /etc/fil-one/seal-token.expired-$(date -u +%Y%m%dT%H%M%SZ)
```

## Restore OpenBao and the platform

From the node checkout, run:

```sh
cd /root/fil-one/infra-nodes
scripts/host/provision-platform.sh
```

Enter the wrapping token when prompted. Because the existing OpenBao store is
already initialised, enter the root token stored in the operator password
manager when the region-key step asks for it. The script should report that the
region key already exists, start OpenBao, regenerate the volatile environment
files, and finish the platform health check.

Verify OpenBao before starting the applications:

```sh
docker exec -i filone-openbao bao status -format=json
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

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

After recovery, remove the moved expired token once it is no longer needed:

```sh
rm -f /etc/fil-one/seal-token.expired-<timestamp>
```
