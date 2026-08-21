# Runbook

Bringing up a FilOne Appliance node, and what to do when one misbehaves.

- [Prerequisites in other repositories](#prerequisites-in-other-repositories)
- [Bringing up a node](#bringing-up-a-node)
- [Onboarding by hand](#onboarding-by-hand)
- [Day-to-day operations](#day-to-day-operations)
- [When something is wrong](#when-something-is-wrong)

## Prerequisites in other repositories

Two things a node needs are built elsewhere. The first blocks everything; the second blocks
onboarding.

**The transit key at central**, in infra-central, on the existing `transit/` mount. Without it the
node's OpenBao starts and stays sealed, and nothing else on the node can run.
`scripts/operator/mint-seal-token.sh` creates the key if it is missing, so an operator with a
central token that can write `transit/keys/*` gets it as a side effect of minting the token.

**The onboarding Lambda**, also in infra-central. Until it exists, do the four registration steps by
hand — see [Onboarding by hand](#onboarding-by-hand) — and treat that section as temporary.

## Bringing up a node

### 1. The state bucket, once per account

```sh
cd terraform/envs/bootstrap/nonprod
```

This root keeps its state in the bucket it creates, so the first apply cannot use the S3 backend.
Comment out the `backend "s3"` block in `versions.tofu`, apply against the local backend, restore the
block, and migrate:

```sh
tofu init
tofu apply
# restore the backend block, then:
tofu init -migrate-state
```

Every root after this one is ordinary: `tofu init` and go.

### 2. The node

```sh
tofu -chdir=terraform/envs/dev init
tofu -chdir=terraform/envs/dev apply
```

This creates the VM, both volumes, the Elastic IP, the security group, the DNS records and the IAM
role, and hands cloud-init the bootstrap script. Bootstrap takes two to three minutes after the
apply returns.

Check it finished:

```sh
scripts/operator/ssm-session.sh dev
sudo -i
cat /etc/filone/bootstrap-complete     # a timestamp; absent means bootstrap died
tail -50 /var/log/filone-bootstrap.log
findmnt /mnt/filone/control /mnt/filone/data
docker network ls | grep filone
```

### 3. The seal token

Only possible now: the token is bound to the address the apply just allocated.

```sh
BAO_TOKEN=<central token> scripts/operator/mint-seal-token.sh dev
```

It prints the token once. Nothing stores it on the operator's machine.

### 4. The platform

In an SSM session on the node:

```sh
sudo -i
cd /opt/filone/infra-nodes
scripts/host/provision-platform.sh
```

It asks for the seal token, initialises OpenBao, and prints **one recovery key and one root token**.
Both are printed once and stored nowhere on the node. Put both in 1Password before continuing: with
neither, the only way back into this OpenBao is to rebuild the node and re-onboard it.

It then asks for the root token back, to create the deploy token and the KV mount; installs the
identity tooling (ucantool and cast, pinned in `nodes/dev/node.env`); generates the node's keys;
asks for the chain.love and Grafana Cloud tokens; and starts Postgres, Caddy and Alloy.

Certificates are issued on Caddy's first start. If the DNS records have not propagated yet, Caddy
retries and the deploy's health gate may time out; re-running `deploy-platform.sh` is safe.

### 5. Onboarding, then the apps

```sh
FILONE_ONBOARD_FUNCTION=<lambda> scripts/operator/onboard.sh dev
```

Then on the node:

```sh
scripts/host/provision-apps.sh
```

Piri's first start runs `piri init`, which calls the registrar for approval. A 403 there means the
node's DID is not on the delegator's allow list, which means onboarding did not complete.

`provision-apps.sh` finishes with acceptance checks: OpenBao restarts and unseals, Piri answers
`/readyz`, Ingot answers `/health`, and both hostnames serve over HTTPS with issued certificates.

### 6. The timer

```sh
systemctl enable --now filone-reconcile.timer
systemctl enable --now filone-seal-token-renew.timer
systemctl list-timers | grep filone
```

From here, changes reach the node by being merged.

## Onboarding by hand

Temporary, for as long as infra-central has no onboarding Lambda. Four steps, in this order. The
first must precede Piri's first `piri init`.

Read the node's DIDs and its Piri delegation first, in an SSM session on the node:

```sh
sudo -i
export BAO_TOKEN=$(cat /etc/filone/bao-token)
read_field() {
  docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN filone-openbao \
    bao kv get -mount=filone -field="$2" "$1"
}
read_field piri did
read_field ingot did
read_field piri sprue_proof
```

**1. Allow-list the Piri DID at the delegator.** Its DynamoDB table takes the DID as its hash key,
so this one can be written directly with AWS credentials for the account, without going near a task:

```sh
aws dynamodb put-item --table-name fc-dev-delegator-allow-list \
  --item '{"did": {"S": "<piri did>"}}'
```

**2. Register the provider with sprue**, and **3. add it to hilt** in region `us-east-9`. Both are
admin CLI calls inside a Fargate task, and no service in infra-central has ECS Exec enabled, so
these need either ECS Exec turned on for the duration or the equivalent writes made against the
databases. The smelt scripts `staging-register-piri.sh` and `staging-register-ingot.sh` are the best
statement of the arguments and the ordering.

**4. Issue hilt's delegation to the Ingot DID**, covering `/s3/request/authorize` and the four
`/s3/bucket/*` commands, signed with hilt's identity key. Store it on the node:

```sh
printf '%s' '<proof>' | docker exec -i \
  -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN filone-openbao \
  bao kv patch -mount=filone ingot hilt_proof=-
```

Without step 4, `deploy-apps.sh` refuses to start Ingot and says so.

## Day-to-day operations

**Deploy a new image.** Edit `nodes/dev/apps/versions.env`, merge. Within five minutes the node
pulls, waits for a safe proving window, restarts Piri and then Ingot, and health-gates both.

**Deploy by hand**, without waiting for the timer:

```sh
sudo -i /opt/filone/infra-nodes/scripts/host/reconcile.sh
```

**Upgrade ucantool or cast.** Edit the pins in `nodes/dev/node.env`, merge, then run
`sudo -i /opt/filone/infra-nodes/scripts/host/install-tools.sh` on the node. Reconcile does not run
the install — only key generation uses these tools — so the new binary lands when the script runs,
not when the commit merges.

**Rotate a secret.** Write the new value into OpenBao, then run `deploy-platform.sh` or
`deploy-apps.sh`. Rendering compares by content, so only the services whose files changed restart.

The Postgres **admin** password is the exception. The image reads `POSTGRES_PASSWORD` only when it
initialises an empty data directory, so writing a new one into OpenBao leaves the cluster on the old
one and `postgres-init` starts failing authentication. Change it in the database first, then in
OpenBao:

```sh
docker exec -it filone-platform-postgres-1 psql -U admin -d admin \
  -c "ALTER ROLE admin WITH PASSWORD '<new>'"
```

The per-service roles have no such problem: `postgres-init` runs `ALTER ROLE` on every deploy, so
rotating those is a write to OpenBao and a deploy.

**Take a node out of service.** Revoke its seal token at central and restart its OpenBao. It comes
back sealed, and every deploy on it fails at the first step.

```sh
# at central
bao token revoke -accessor <accessor>
```

**Read the logs.** Everything ships to Grafana Cloud, labelled with the node and its region. On the
box:

```sh
journalctl -u filone-reconcile.service -n 200
docker logs --tail 200 filone-piri
```

## When something is wrong

**OpenBao is sealed.** `docker logs filone-openbao` names which half failed: the token was refused
(revoked, expired, or the request came from an address the token is not bound to) or the transit key
does not exist. A node whose Elastic IP changed has a token bound to the old one and needs a new
token.

**`deploy-apps.sh` says OpenBao has no hilt-to-ingot delegation.** Onboarding has not finished. See
[Onboarding by hand](#onboarding-by-hand).

**`deploy-apps.sh` says PAYER_ADDRESS is still the placeholder.** Read the address the central dev
stage's signing service pays from — it is in that stage's provision output and in SSM under
`/forge-central/dev/signing-service/` — and commit it to `nodes/dev/node.env`.

**Piri crash-loops with a 403 from the registrar.** Its DID is not on the delegator's allow list.

**Piri crash-loops on the chain endpoint.** A 401 from the provider means the chain.love token in
OpenBao is wrong or expired; rotate it there and re-run `deploy-apps.sh`. Piri sends the token
itself, from `PIRI_PDP_LOTUS_AUTH_TOKEN`, so check that the variable actually reached the container:
`docker inspect filone-piri` shows its environment.

**The proving gate never lets a deploy through.** `pdp-gate.sh` waits 45 minutes by default. If Piri
reports "not safe" for that whole time, the deploy aborts rather than risk a proof; re-run it after
the challenge window. If Piri never reports its state at all, the gate proceeds with a warning,
which is expected before the node has a proof set and worth investigating afterwards.

**Caddy will not get a certificate.** ACME needs port 80 reachable and DNS pointing at this node.
Check that the A records resolve to the Elastic IP and that the security group still allows 80.

**Uploads fail with `CandidateUnavailable`.** sprue does not know about this provider: registration
step 2 did not happen, or its weight is zero.

**Hilt rejects every tenant in the region.** The region label does not match. It has to be identical
in `nodes/dev/node.env`, in Ingot's rendered config, in hilt's `provider add`, and in the
`AWS_REGION` the client signs with.

**The deadman alert fired.** The node stopped reconciling. Check
`systemctl status filone-reconcile.timer` and the last few
`journalctl -u filone-reconcile.service` runs; a failing pass leaves its error there.
