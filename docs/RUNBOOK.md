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

### Staging on Servers.com

The staging appliance is not an EC2 node. Its host owns Lotus and Caddy, and
FilOne must leave both intact. Its checkout is `/root/fil-one/infra-nodes`; its
control and data directories are `/mnt/data/filone/control` and
`/mnt/data/filone/data`.

Apply the DNS-only root and confirm both names resolve to `23.83.66.244`:

```sh
tofu -chdir=terraform/envs/staging init
tofu -chdir=terraform/envs/staging apply
dig +short piri-0.staging.fil-forge.com
dig +short s3.eu-central-3.staging.filonecontent.com
```

Check out this repository at `/root/fil-one/infra-nodes`, then run:

```sh
cd /root/fil-one/infra-nodes
scripts/host/bootstrap-staging.sh
docker run --rm --add-host host.docker.internal:host-gateway curlimages/curl \
  ws://host.docker.internal:1234/rpc/v1
```

Bootstrap creates only FilOne directories, tmpfs paths, the shared Docker
network, node config, systemd units, the Caddy import and the FilOne UFW rule.
It validates the combined host Caddy configuration before reloading
`caddy-guppy`.

At infra-central, confirm `eu-central-3` is in `appliance_regions`, get the
staging `wallet_addresses` payer address and commit it to `nodes/staging/node.env`.
Mint a wrapping token with `STAGE=staging`, `REGION=eu-central-3` and
`NODE_IP=23.83.66.244`. On the host run `provision-platform.sh`, saving the
OpenBao recovery key and root token, then provide the wrapping token and
Grafana token. Staging uses its local unauthenticated Lotus RPC and therefore
does not ask for a Chain.Love token.

Run `onboarding-request.sh`, fund its printed Piri owner wallet with
Calibration testnet FIL, and send its DID, URL and proof to infra-central. Run
`onboard-appliance` there for `staging/eu-central-3`, install its returned
Ingot proof with `store-hilt-proof.sh`, then run `provision-apps.sh`. Enable
both FilOne timers and check public Piri, Ingot, the status document and an
OpenBao restart/unseal. Finish with:

```sh
scripts/ci/smoke-test.sh staging
```

`nodes/dev/node.env` describes the EC2 dev node and the accounts it talks to, and the values below name
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

It then asks for the root token back twice, to create the deploy token and the KV mount and then the
region key Ingot encrypts objects under; installs the identity tooling (ucantool and cast, pinned in
`nodes/dev/node.env`); generates the node's keys; asks for the chain.love and Grafana Cloud tokens;
and starts Postgres, Caddy and Alloy.

A node provisioned before the region key existed gets it from a separate run of the same steps:

```sh
scripts/host/provision-regionkey.sh
```

It asks for the root token, enables the transit engine, creates `region-us-east-9`, writes the
`ingot-regionkey` policy and mints the token Ingot holds. Re-running it is also how a revoked or
lapsed token is replaced: the engine, the key and the policy are left alone and a fresh token
overwrites the old one.

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
Ingot identity is not in it: central derives the same did:web from the stage's domain, so there is
nothing to mistype. The script prints it anyway, because the node has to be configured with the
matching string — `INGOT_DID` in `nodes/<node>/node.env`, which `deploy-apps.sh` renders into
Ingot's `identity.service_id`. Central's delegation is addressed to that DID, and a mismatch shows
up only when Ingot's first S3 call is refused.

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

That first start also registers the provider and creates the proof set, and waits for both
transactions to land, which takes minutes. The first `provision-apps.sh` prints Piri's own log while
it waits, prefixed `piri |`, so a registration or a proof-set transaction that never confirms is
visible as it happens. Later runs skip init and print nothing extra.

`provision-apps.sh` finishes with acceptance checks: OpenBao restarts and unseals, Piri answers
`/readyz`, Ingot answers `/health`, and both hostnames serve over HTTPS with issued certificates.

It then installs the systemd units from the checkout, so the timers below exist whatever revision
cloud-init bootstrapped the box from.

### 6. The timers

```sh
systemctl enable --now filone-reconcile.timer
systemctl enable --now filone-seal-token-renew.timer
systemctl list-timers | grep filone
```

From here, changes reach the node by being merged. The node tracks whatever `FILONE_GIT_REF` in
`/etc/filone/node.conf` names, which cloud-init writes as `main`.

## Day-to-day operations

**Deploy a new image.** Nothing to do. Piri and Ingot dispatch their new digest here when they
publish a `:main` image, `bump-deployed-image.yml` opens the pull request that rewrites
`nodes/dev/apps/versions.env`, and auto-merge lands it once `tofu`, `shell` and `compose` pass.
Within five minutes of the merge the node pulls, waits for a safe proving window, restarts Piri and
then Ingot, and health-gates both.

Two ways in by hand. Run the same workflow with a digest you read off the registry:

```sh
gh workflow run bump-deployed-image.yml -f service=piri \
  -f digest="$(crane digest ghcr.io/fil-forge/piri:main)"
```

Or write the pin in a branch of your own and open the pull request yourself:

```sh
scripts/ci/set-node-pin.sh piri "$(crane digest ghcr.io/fil-forge/piri:main)"
```

`set-node-pin.sh` is the only thing that knows how a pin is written, so both routes and the workflow
produce the same line. It prints `changed=true` or `changed=false` and fails on an unknown service, a
malformed digest or a pin somebody moved to another tag.

A deploy that fails is retried on the next pass. Each project records the revision it was last
deployed from, so reconcile compares against that rather than against the previous HEAD; the failed
commit stays outstanding until a deploy of it succeeds.

**Check a node by hand.** The smoke test needs no credentials and checks the node the way the world
sees it:

```sh
scripts/ci/smoke-test.sh dev
curl -s https://piri-0.latest.dev.fil-forge.com/.well-known/filone-node-status.json | jq
```

The document carries a revision per stamp. `reconcile` is the commit the node has reached, advanced
on every pass; `apps` and `platform` move only when that project deploys. The smoke test waits on
`reconcile` and compares the running digests against the pins at `apps`, which is what proves a bump
took. `smoke.yml` runs the same test after every merge and hourly.

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

**Rotate Ingot's region-key token.** Run `provision-regionkey.sh` and then `deploy-apps.sh`. The old
token is left valid until it lapses; revoke it at `bao token revoke -accessor <accessor>` if it was
taken rather than merely aged.

The region KEK itself is a different matter. Rotating `transit/keys/region-us-east-9` leaves every
stored wrap on the old version, which transit still decrypts, so a rotation is safe and a
`min_decryption_version` bump is not: it makes every object written before it unreadable. There is
no rewrap campaign in this repository yet, and Ingot's token cannot run one.

**Reissue Piri's delegation to sprue after SPRUE_DID changes.** Run `keygen.sh` again. It compares
the delegation's stored audience against the current `SPRUE_DID` and reissues automatically when
they differ, so this is the same command as the first run. sprue needs nothing from this beyond the
new proof reaching Piri on the next `deploy-apps.sh`; the old delegation just becomes one addressed
to a DID sprue no longer answers to.

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

Losing the control volume loses the node's keys, so the rebuilt node comes back with a new Piri
DID and central still carries the old one. Ingot is unaffected as long as its hostname holds: the
`did:web` is derived from the region label and the content domain, both of which central also holds,
so a rebuilt node publishes a new key at the same DID and hilt's delegation to it stays valid.
Everything below is about Piri. A node whose Ingot hostname *does* change is a different case, at
the end of this section.

**1. Rebuild.** Attach a fresh control volume (or replace the instance and let cloud-init mount
one), then run `provision-platform.sh`. It initialises an empty OpenBao and generates new
identities. The transit key at central is per-node, not per-identity, so it stays. The unseal token
lives on the root volume and survives unless the instance was replaced too; if it was, ask central
for a new wrapping token.

**2. Remove the old identity at central.** Ask whoever runs infra-central to drop the old Piri DID
from the delegator's allow list and to deregister or zero-weight the old provider at sprue. hilt's
provider row is keyed by the Ingot DID, which the rebuild does not change, so it stays as it is.

**3. Onboard the new Piri DID.** [Step 5](#5-onboarding-then-the-apps) again, then
`provision-apps.sh` and the timers. hilt's delegation to Ingot is unchanged and central still holds
it in SSM, so ask for the same `ingot-proof.txt` back rather than a reissue, and store it with
`store-hilt-proof.sh`: the rebuilt OpenBao has no copy of it.

The data volume still holds the old identity's blobs and spool. Dev data is disposable; wipe it and
start clean rather than carry data the new identity cannot serve.

**When the Ingot DID changes too**, because the region label or the content domain moved, central
carries two pieces of state addressed to an identity that no longer exists: hilt's `provider` row,
keyed by the DID, and the delegation stored at
`/forge-central/<stage>/appliance/<region>/hilt-ingot-s3-proof`, keyed by the region. Ask whoever
runs infra-central to clear both before you onboard:

```sh
make retire-region STAGE=dev REGION=us-east-9
```

It prints what it found, asks for confirmation, then deletes the row and the parameter. Run it
before onboarding. Neither problem it fixes shows up in the onboarding dry run: that reads hilt by
the *new* DID, finds nothing and reports a clean registration, so the UNIQUE conflict on the
provider row only surfaces once `Apply` has written the allow-list and sprue entries. The stale
delegation raises no error at central at all; it shows up as a 403 on Ingot's first S3 call.
Onboarding's log line has to read "issued hilt's S3 delegation to the appliance" with the new Ingot
DID as the audience. "Returning the delegation issued earlier" means the retire did not take.

`retire-region` leaves `unseal-token.accessor` alone, which is what the onboard phase checks before
it will admit a region at all. It does not touch sprue's registration for the old Piri DID either,
which is the same tidying step 2 above describes.

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

**`deploy-apps.sh` or a reconcile pass says OpenBao has no token for the region wrap key.** The node
predates the region key, or its token was revoked. Run `provision-regionkey.sh`. Until it runs,
every reconcile pass stops at the renewal and every deploy stops at the token read, including
deploys of unrelated changes.

**Ingot starts and answers `/health`, and every object write fails.** Ingot checks neither the
socket path nor the token at startup, so a wrong one reaches the S3 layer as an unclassified error
on the first PutObject or GetObject. Three causes, in the order worth checking:

- The token has lapsed. `bao token lookup` under it says so; `provision-regionkey.sh` replaces it.
- OpenBao is sealed and answers 503 on the socket. No renewal covers this, because a reseal is the
  kill lever central pulls; the node is out of service until it unseals.
- The socket is not there. `docker exec filone-openbao ls -l /openbao/logs/api.sock` shows it, and
  `docker exec filone-ingot ls -l /run/openbao/api.sock` shows the same file from Ingot's side. A
  platform deploy that predates the unix listener leaves the first missing.

**A write fails for one tenant and works for others.** That tenant's `did:plc` document carries no
`#wrap` verification method, so there is no key to encrypt to. The region wrap is unaffected and the
rest of the region keeps working. `curl https://plc.latest.dev.fil-forge.com/<did>` shows the
document Ingot resolved.

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
the challenge window. A Piri that owes proofs and will not report its state at all is treated the
same way, most often because the chain RPC is unreachable.

**The gate says `piri-config.toml` is missing.** The container is running but the file is not there
yet, which is where a node sits while `piri init` is still working and where it stays if init died.
`docker logs filone-piri` says which of the two it is. The gate lets the deploy through only when
`piri-base-config.applied.toml` is missing too, because init writes that file last and a node that
has never got that far holds no proof set. A missing config next to a present snapshot aborts the
deploy: init has completed here before, so Piri may still owe a proof. Restore the config, or
`docker stop filone-piri` if the node is being decommissioned.

**Caddy will not get a certificate.** ACME needs port 80 reachable and DNS pointing at this node.
Check that the A records resolve to the Elastic IP and that the security group still allows 80.

**Uploads fail with `CandidateUnavailable`.** sprue does not know about this provider: registration
step 2 did not happen, or its weight is zero.

**Hilt rejects every tenant in the region.** The region label does not match. It has to be identical
in `nodes/dev/node.env`, in Ingot's rendered config, in hilt's `provider add`, and in the
`AWS_REGION` the client signs with.

**A `filone-alerts` message arrived.** It says which of two things happened.

When the failing commit is an image bump, the message carries a further line naming the service
commit that produced the image and who wrote it, read from the source commit link the bump left in
the commit body. A lookup that fails drops the line and sends the alert anyway, and the run log names
the repository and commit it could not read.

*The dev node never reached this commit.* The commit merged and the node has not deployed it within
an hour. `journalctl -u filone-reconcile.service -n 200` on the box shows which: a pass that never
ran, a proving gate that has not opened, a deploy that failed, or a node pointed at another ref by
`FILONE_GIT_REF` in `/etc/filone/node.conf`. The entries below cover each.

*The dev node failed its smoke test.* The node has the commit and is not serving what the commit
pins, so suspect the image. The run's log names the failing check. A check that says the deployed
revision is not in this checkout usually means the clone is behind, so `git fetch` and run it again;
if the revision is still nowhere on origin, the node is following another ref and
`FILONE_GIT_REF` in `/etc/filone/node.conf` says which. Rolling back is a pin bump like any other:

```sh
gh workflow run bump-deployed-image.yml -f service=piri -f digest=<the digest that worked>
```

**A bump pull request is sitting open.** The refresh workflow rebuilds every open bump on current
main, so a stale base is not the reason. It leaves one alone in exactly one case: main moved that
service to a third digest while the branch sat there, which makes the digest the node should run a
question rather than an edit. The run says so in its log. Decide which digest is wanted, then close
the pull request or dispatch a bump for the digest you want:

```sh
gh workflow run bump-deployed-image.yml -f service=piri -f digest=sha256:...
```

**The deadman alert fired.** The node stopped reconciling. Check
`systemctl status filone-reconcile.timer` and the last few
`journalctl -u filone-reconcile.service` runs; a failing pass leaves its error there.
