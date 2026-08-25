# infra-nodes

Deployment configuration for FilOne Appliance nodes: the regional half of the Forge network.

An appliance is one Piri storage node and one Ingot S3 gateway, running under Docker Compose on a
single EC2 VM, with the local OpenBao, Postgres, Caddy and Grafana Alloy they need. Central services
live in [infra-central](https://github.com/fil-forge/infra-central); a node talks to them over public
HTTPS and unseals its OpenBao against theirs.

One node so far: `dev`, in us-east-2, paired with infra-central's dev stage.

## Contents

- [How a node fits together](#how-a-node-fits-together)
- [Repository layout](#repository-layout)
- [How a change reaches a node](#how-a-change-reaches-a-node)
- [Secrets](#secrets)
- [Bringing up a node](#bringing-up-a-node)
- [What survives a destroy](#what-survives-a-destroy)
- [Before production](#before-production)
- [Development](#development)
- [Related](#related)

## How a node fits together

```
                    Caddy  (80/443, ACME)
                      │
        ┌─────────────┴─────────────┐
   piri.<suffix>              ingot.<suffix>
        │                           │
      Piri ──────────────────────► Ingot
        │                           │
        ├──────── Postgres ─────────┘
        │              │
   chain.love      OpenBao ──── unseals against ssm.<suffix> (infra-central)
```

Two Compose projects. **platform** is OpenBao, Postgres, Caddy and Alloy; **apps** is Piri and
Ingot. They are separate because they restart on different terms: an apps deploy waits for Piri's
proving window, and a platform deploy never has to.

Caddy is the only process listening on a public interface. Piri, Ingot, Postgres and OpenBao publish
no ports at all — the first three are reachable on the shared `filone` Docker network, and OpenBao
is not even on it.

## Repository layout

```
terraform/
  modules/
    shared/constants/   account ids, the Route53 zone, the state bucket name
    tfstate/            the state bucket, created by the bootstrap root
    node/               a node: EC2, two EBS volumes, an Elastic IP, a security
                        group, DNS, IAM, and the cloud-init that prepares the box
  envs/
    bootstrap/nonprod/  applied by hand, once per account
    dev/                the dev node
nodes/
  dev/
    node.env            everything about this node that is not a secret
    platform/           OpenBao, Postgres, Caddy, Alloy
    apps/               Piri, Ingot
scripts/
  host/                 run on the node: provision, deploy, reconcile, keygen, onboarding
  operator/             run from a laptop with AWS credentials for the node's account
systemd/                the reconcile timer and the seal-token renewal timer
docs/
  RUNBOOK.md            bringing a node up, and what to do when it will not
  decisions/            why the node is shaped the way it is
```

Each node owns its Compose files and templates rather than sharing a parameterized stack. A change
is made on one node, watched, and copied to the next; a shared stack would change every node at the
same instant, which is the failure this layout exists to prevent. Node state is its directory in
git.

## How a change reaches a node

Merge it. `filone-reconcile.timer` fetches `origin/main` every five minutes, works out whether the
new commits touch the platform project, the apps project or neither, and runs only those deploys.

An apps deploy waits for `piri status upgrade-check` to report a safe window before restarting Piri,
so an image bump never costs a proof. The gate runs in dev too — a mechanism that only runs in
production is a mechanism nobody has tested.

Each completed pass stamps `deploy_last_success_timestamp`, which Alloy ships to Grafana Cloud. It
is stamped even when nothing was deployed, because it exists to go stale when the node stops
reconciling.

## Secrets

Every secret a node holds is in the OpenBao on that node, except the seal token that unseals it and
the certificates Caddy manages itself. That OpenBao unseals by asking the central one to decrypt its
seal key. Revoking the node's token at central and restarting it leaves it sealed and serving
nothing: that is the kill lever.

Keys are generated on the node and never leave it. Provisioning creates the two Ed25519 identities,
the EVM owner wallet and every password directly into the local OpenBao. The operator supplies three
things by hand and nothing else: the wrapping token the seal token is claimed with, the chain.love
access token and the Grafana Cloud push token.

Piri and Ingot read their configuration from files, secrets included, so the deploy scripts render
what they need into `/run/filone/secrets` — a root-only tmpfs, mounted read-only into the
containers, re-rendered on every deploy and compared by content so an unchanged deploy restarts
nothing. Nothing secret is written to a disk that survives a reboot.

## Bringing up a node

Six steps, in [docs/RUNBOOK.md](docs/RUNBOOK.md) with the commands:

1. Apply `terraform/envs/bootstrap/nonprod` by hand, once per account.
2. Apply `terraform/envs/dev`. cloud-init prepares the box; SSM Session Manager reaches it.
3. Have central mint the seal token, which is bound to the Elastic IP the apply just allocated,
   and send back the wrapping token that claims it.
4. Run `provision-platform.sh` on the node: initialise OpenBao, install the identity tooling,
   generate keys, start the platform.
5. Run `onboarding-request.sh`, send what it prints to Forge Central, and install the delegation
   they return with `store-hilt-proof.sh`. Then run `provision-apps.sh`.
6. Enable `filone-reconcile.timer` and `filone-seal-token-renew.timer`.

Steps 3 and 5 are a conversation with Forge Central. Each side sends the other what it cannot
produce itself, and neither needs a credential for the other's account.

## What survives a destroy

The instance is disposable. Terminating and replacing it loses the OS, the images and the checkout,
all of which are rebuilt from this repository.

`prevent_destroy` is on the two EBS volumes and the Elastic IP:

- the **control volume** holds the node's identity, its Postgres data and its certificates
- the **data volume** holds Piri's blobs and Ingot's spool
- the **Elastic IP** is what the seal token is bound to and what both hostnames resolve to

Losing the control volume loses the node's identity, which means new DIDs and a full re-onboarding
at central. Dev takes no backups, by decision.

## Before production

Two things this repository should have before a node carries anything that matters.

**A backup strategy.** Dev runs with none. Production needs snapshots of the control volume, OpenBao
raft snapshots off the box, or scheduled `pg_dump` — and a restore that has actually been run,
because the failure this protects against is the one where the node's identity is gone.

**Piri and Ingot reading their secrets from OpenBao.** Both take configuration as files today,
including the Postgres DSN, the root S3 credentials and their private keys, which is why the deploy
scripts render secrets into a tmpfs at all. RFC 21 asks for nothing secret in a plain file; a tmpfs
file is still a file. With both services able to fetch their own secrets, the rendering step goes
away and so does the tmpfs.

## Development

`tofu`, `docker`, `shellcheck`. There is nothing to build.

```sh
tofu fmt -recursive terraform/
tofu -chdir=terraform/envs/dev init -backend=false && tofu -chdir=terraform/envs/dev validate
shellcheck scripts/host/*.sh scripts/operator/*.sh
```

CI runs the same three, plus `docker compose config` on both projects.

Every OpenTofu root is OpenTofu-only, enforced by a `versions.tf` that no Terraform release
satisfies. Running `terraform` in one of these directories stops at that constraint rather than
writing a state file OpenTofu then refuses to read.

## Related

- [infra-central](https://github.com/fil-forge/infra-central) — the services a node registers with,
  and the OpenBao it unseals against
- [smelt](https://github.com/fil-forge/smelt) — the single-VM staging deployment these Compose files
  come from
- [piri](https://github.com/fil-forge/piri), [ingot](https://github.com/fil-forge/ingot) — the two
  services a node exists to run
- [docs/decisions/2026-08-initial-design.md](docs/decisions/2026-08-initial-design.md) — why the node
  is shaped this way
