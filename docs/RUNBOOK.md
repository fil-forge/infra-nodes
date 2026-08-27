# Runbook

Bringing up a FilOne Appliance node, and what to do when one misbehaves.

- [Prerequisites in other repositories](#prerequisites-in-other-repositories)
- [Bringing up a node](#bringing-up-a-node)
- [Day-to-day operations](#day-to-day-operations)
- [Re-onboarding after identity loss](#re-onboarding-after-identity-loss)
- [When something is wrong](#when-something-is-wrong)

## Prerequisites in other repositories

**The transit key at central**, in infra-central, on the existing `transit/` mount. Without it the
node's OpenBao starts and stays sealed, and nothing else on the node can run. It is created by
adding this node's region label to `appliance_regions` in the stage's `terraform.tfvars` and
applying, which infra-central's
[appliance onboarding guide](https://github.com/fil-forge/infra-central/blob/main/docs/appliance-onboarding.md)
covers.

That guide is the other half of steps 3 and 5 below. Whoever runs infra-central mints the unseal
token, supplies the payer address and registers the node; nothing in this repository can do any of
that, and nothing in that one can read this node's keys.

## Bringing up a node

`nodes/dev/node.env` describes the dev node and the accounts it talks to, and the values below name
those accounts rather than anything in this repository. They are set for dev. A node added later
needs its own copy of them, and the deploys in steps 4 and 5 refuse to run while any is still the
placeholder it was committed with. Set them in the checkout, commit and merge: the node resets to
`origin/main` on every reconcile pass, so an edit made on the box is gone within five minutes.

`GRAFANA_LOGS_USER` and `GRAFANA_METRICS_USER` are the Loki and Prometheus instance ids of the
Grafana Cloud stack the node ships to. Both are on the stack's details page in the Grafana Cloud
portal, on the Loki tile and the Prometheus tile, and they differ from each other. Those same two
tiles carry the push URLs, which belong in `GRAFANA_LOGS_URL` and `GRAFANA_METRICS_URL`: each names
the cluster its stack sits on, so another stack pushes elsewhere.

`PAYER_ADDRESS` is the wallet the central signing service pays from for the stage the node joins.
Only the central account can read it, so ask whoever runs infra-central; their runbook says where
they get it. It is a public address, so any channel will do.

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
findmnt /mnt/filone/control
findmnt /mnt/filone/data
docker network ls | grep filone
```

### 3. The unseal token

Central mints it, and only now: the token is bound to the address the apply just allocated. The
apply printed the Elastic IP; to read it again:

```sh
tofu -chdir=terraform/envs/dev output -raw public_ip
```

Send that address to whoever runs infra-central, and they run

```sh
make mint-appliance-token STAGE=dev REGION=us-east-9 NODE_IP=<the elastic ip>
```

What comes back to you is a **wrapping token**, not the unseal token itself. The credential stays
inside the central OpenBao until the node claims it in step 4. The wrapping token can be spent once
and expires in 24 hours, so chat is an acceptable channel for it; a view-once 1Password link is
better.

### 4. The platform

In an SSM session on the node:

```sh
sudo -i
cd /opt/filone/infra-nodes
scripts/host/provision-platform.sh
```

It asks for the wrapping token, exchanges it at central for the unseal token, initialises OpenBao,
and prints **one recovery key and one root token**.
Both are printed once and stored nowhere on the node. Put both in 1Password before continuing: with
neither, the only way back into this OpenBao is to rebuild the node and re-onboard it.

It then asks for the root token back, to create the deploy token and the KV mount; installs the
identity tooling (ucantool and cast, pinned in `nodes/dev/node.env`); generates the node's keys;
asks for the chain.love and Grafana Cloud tokens; and starts Postgres, Caddy and Alloy.

The Grafana Cloud token is an access policy token scoped to the stack with `logs:write` and
`metrics:write`, created under **Security -> Access Policies** in the Grafana Cloud portal. That page
needs Admin on the org, so ask whoever holds it if the page tells you to.

Certificates are issued on Caddy's first start. If the DNS records have not propagated yet, Caddy
retries and the deploy's health gate may time out; re-running `deploy-platform.sh` is safe.

### 5. Onboarding, then the apps

On the node:

```sh
scripts/host/onboarding-request.sh
```

It prints the node's Piri DID, its public URL and the delegation it signed with its own Piri key,
in the form central's `make onboard-appliance` takes. Send that to whoever runs infra-central. The
Ingot identity is not in it: central derives that from the region label, so there is nothing to
mistype.

While central works on that, fund the node's owner wallet. Piri registers itself in the provider
registry on its first start, and that transaction sends 5 tFIL from this wallet, so send it at least
6 from a Calibration faucet. The address is printed by `onboarding-request.sh`, and also readable
directly:

```sh
docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$(cat /etc/filone/bao-token)" \
  filone-openbao bao kv get -mount=filone -field=owner_wallet_address piri
```

This is the only thing the node ever pays for. Proofs are paid by the central signing service from
`PAYER_ADDRESS`.

Central sends back ingot-proof.txt, hilt's delegation to this node's Ingot and the one piece of
onboarding only central can sign. It lands on your machine, and there is no SSH on the node to copy
it across, so pass it to `store-hilt-proof.sh` over stdin:

```sh
scripts/host/store-hilt-proof.sh -
```

Paste the delegation, press Enter, then Ctrl-D. It is a single line short enough to paste, and the
script strips whitespace, so the extra newline does no harm. Then start the apps:

```sh
scripts/host/provision-apps.sh
```

A second onboarding run at central is safe. It performs only what is missing and returns the same
delegation byte for byte, so a node that lost its copy can ask for it again.

Piri's first start runs `piri init`, which calls the registrar for approval. A 403 there means the
node's DID is not on the delegator's allow list, which means onboarding did not complete.

`provision-apps.sh` finishes with acceptance checks: OpenBao restarts and unseals, Piri answers
`/readyz`, Ingot answers `/health`, and both hostnames serve over HTTPS with issued certificates.

### 6. The timers

```sh
systemctl enable --now filone-reconcile.timer
systemctl enable --now filone-seal-token-renew.timer
systemctl list-timers | grep filone
```

From here, changes reach the node by being merged. The node tracks whatever `FILONE_GIT_REF` in
`/etc/filone/node.conf` names, which cloud-init writes as `main`.

## Day-to-day operations

**Deploy a new image.** Edit `nodes/dev/apps/versions.env`, merge. Within five minutes the node
pulls, waits for a safe proving window, restarts Piri and then Ingot, and health-gates both.

A deploy that fails is retried on the next pass. Each project records the revision it was last
deployed from, so reconcile compares against that rather than against the previous HEAD; the failed
commit stays outstanding until a deploy of it succeeds.

**Deploy by hand**, without waiting for the timer:

```sh
sudo -i /opt/filone/infra-nodes/scripts/host/reconcile.sh
```

**Test a branch before it merges.** Point the node at it and let the next pass pick it up:

```sh
sed -i 's|^FILONE_GIT_REF=.*|FILONE_GIT_REF=my-branch|' /etc/filone/node.conf
```

Set it back to `main` before the branch is deleted. A node tracking a ref that no longer exists
fails the reset, so reconcile stops and the deploy deadman goes stale.

`/etc/filone/node.conf` is the only statement of the ref. Reconcile reads it on every pass, so an
environment variable passed to a single run would be undone five minutes later.

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

**Take a node out of service.** Revoke its unseal token at central and restart its OpenBao. It comes
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

## Re-onboarding after identity loss

Losing the control volume loses the node's keys, so the rebuilt node is a new node: new DIDs, and
central still carries the old ones.

**1. Rebuild.** Attach a fresh control volume (or replace the instance and let cloud-init mount
one), then run `provision-platform.sh`. It initialises an empty OpenBao and generates new
identities. The transit key at central is per-node, not per-identity, so it stays. The unseal token
lives on the root volume and survives unless the instance was replaced too; if it was, ask central
for a new wrapping token.

**2. Remove the old identity at central.** Ask whoever runs infra-central to drop the old Piri DID
from the delegator's allow list and to deregister or zero-weight the old provider at sprue and hilt.
Central's guide covers this: hilt in particular refuses to move a provider and raises the same
"already registered" error whichever region holds the row, so a stale row has to be corrected in its
database.

**3. Onboard the new DIDs.** [Step 5](#5-onboarding-then-the-apps) again, then `provision-apps.sh`
and the timers.

The data volume still holds the old identity's blobs and spool. Dev data is disposable; wipe it and
start clean rather than carry data the new identity cannot serve.

## When something is wrong

**`provision-platform.sh` cannot exchange the wrapping token.** A wrapping token can be spent once,
so a token central refuses inside its 24-hour window is one somebody else has already spent. Treat
it as a compromise: ask central to re-mint with `TOKEN_ARGS=--reissue`, which revokes the token that
was taken, and work out who could read the channel it was delivered on.

**OpenBao is sealed.** `docker logs filone-openbao` names which half failed: the token was refused
(revoked, expired, or the request came from an address the token is not bound to) or the transit key
does not exist. A node whose Elastic IP changed has a token bound to the old one and needs a new
token.

**`deploy-apps.sh` says OpenBao has no hilt-to-ingot delegation.** Onboarding has not finished. Run
`onboarding-request.sh` and install what central returns with `store-hilt-proof.sh`.

**`deploy-apps.sh` says PAYER_ADDRESS is still the placeholder.** Ask whoever runs infra-central for
the address the stage's signing service pays from, and commit it to `nodes/dev/node.env`.

**Piri crash-loops with a 403 from the registrar.** Its DID is not on the delegator's allow list.

**Piri crash-loops on `wallet balance is too low`.** The owner wallet holds less than the 5 tFIL
provider registration sends to the registry. Fund it with at least 6, as [step
5](#5-onboarding-then-the-apps) describes, then re-run `provision-apps.sh`. Exactly 5 is not enough,
because the 5 is the transaction's value and the gas comes out of the same wallet.

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
