# infra-nodes

Deployment configuration for FilOne Appliance nodes: the regional half of the Forge network.

An appliance is one Piri storage node and one Ingot S3 gateway, running under Docker Compose on a
single host, with the local OpenBao, Postgres and Grafana Alloy they need. Central services
live in [infra-central](https://github.com/fil-forge/infra-central); a node talks to them over public
HTTPS and unseals its OpenBao against theirs.

Two nodes: `dev`, an EC2 node in us-east-2 paired with infra-central's dev stage; and `staging`, a
bare-metal Servers.com appliance in eu-central-3 paired with the staging services.

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
 piri-0.<forge>            s3.<region>.<content>
        │                           │
      Piri ──────────────────────► Ingot
        │                           │
        ├──────── Postgres ─────────┘
        │              │
   chain.love      OpenBao ──── unseals against ssm.<forge> (infra-central)
```

On the dev node `<forge>` is `latest.dev.fil-forge.com` and `<content>` is
`latest.dev.filonecontent.com`. Piri and the central services answer on the Forge domain; Ingot
answers on the content one, and that hostname with `did:web:` in front is the identity central
addresses its delegation to. Both names come from [RFC 16][rfc-16].

[rfc-16]: https://github.com/fil-one/RFC/blob/main/rfcs/2026-07-forge-service-identities.md

Two Compose projects. **platform** is OpenBao, Postgres and Alloy; dev also runs Caddy there,
while staging imports its Caddy configuration into the host-owned service. **apps** is Piri and
Ingot. They are separate because they restart on different terms: an apps deploy waits for Piri's
proving window, and a platform deploy never has to.

Piri, Ingot, Postgres and OpenBao publish no public ports. Dev Caddy reaches the apps on the shared
`filone` Docker network. On staging, Piri and Ingot bind only to host loopback and the host-owned
Caddy proxies them; OpenBao is not on the Docker network.

## Repository layout

```
terraform/
  modules/
    shared/constants/   account ids, the Route53 zones, the state bucket name
    tfstate/            the state bucket, created by the bootstrap root
    node/               a node: EC2, two EBS volumes, an Elastic IP, a security
                        group, DNS, IAM, and the cloud-init that prepares the box
  envs/
    bootstrap/nonprod/  applied by hand, once per account
    dev/                the EC2 dev node
    staging/            the bare-metal staging appliance
nodes/
  dev/
    node.env            everything about this node that is not a secret
    platform/           OpenBao, Postgres, Caddy, Alloy
    apps/               Piri, Ingot
scripts/
  host/                 run on the node: provision, deploy, reconcile, keygen, onboarding
  operator/             run from a laptop with AWS credentials for the node's account
  ci/                   run by the workflows, and by a person at a terminal
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

An image bump starts in the service repository rather than here. When piri or ingot publishes a new
`:main` image, its publish workflow dispatches the digest to
[`bump-deployed-image.yml`](.github/workflows/bump-deployed-image.yml), which rewrites the one line
in `nodes/dev/apps/versions.env` and opens a pull request with auto-merge armed. The required checks
still gate it. Merging queues the image; the node deploys it on its next pass.

An apps deploy waits for `piri status upgrade-check` to report a safe window before restarting Piri,
so an image bump never costs a proof. The gate runs in dev too — a mechanism that only runs in
production is a mechanism nobody has tested.

Each completed pass stamps `deploy_last_success_timestamp`, which Alloy ships to Grafana Cloud. It
is stamped even when nothing was deployed, because it exists to go stale when the node stops
reconciling.

The node also publishes what it is running, at
`https://<piri hostname>/.well-known/filone-node-status.json`: the commit each pass and each project
last stamped, and the image digests the two containers are actually on. `reconcile` is the commit the
node has reached, stamped on every pass; `apps` and `platform` move only when that project deploys.
The digests are read off the containers, so a pin the node never applied shows up as a mismatch.

## Secrets

Every secret a node holds is in the OpenBao on that node, except the unseal token that unseals it
and the certificates Caddy manages itself. That OpenBao unseals by asking the central one to decrypt
its seal key. Revoking the node's token at central and restarting it leaves it sealed and serving
nothing: that is the kill lever.

Keys are generated on the node and never leave it. Provisioning creates the two Ed25519 identities,
the EVM owner wallet and every password directly into the local OpenBao. The operator supplies three
things by hand and nothing else: the wrapping token the unseal token is claimed with, the
chain.love access token and the Grafana Cloud push token.

Piri and Ingot read their configuration from files, secrets included, so the deploy scripts render
what they need into `/run/filone/secrets` — a root-only tmpfs, mounted read-only into the
containers, re-rendered on every deploy and compared by content so an unchanged deploy restarts
nothing. Nothing secret is written to a disk that survives a reboot.

## Bringing up a node

Six steps, in [docs/RUNBOOK.md](docs/RUNBOOK.md) with the commands:

1. Apply `terraform/envs/bootstrap/nonprod` by hand, once per account.
2. Apply `terraform/envs/dev` for EC2 dev. For bare-metal staging, apply the DNS-only
   `terraform/envs/staging` root and run `scripts/host/bootstrap-staging.sh` on the server.
3. Have central mint the unseal token, which is bound to the Elastic IP the apply just allocated,
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
- the **Elastic IP** is what the unseal token is bound to and what both hostnames resolve to

Losing the control volume loses the node's keys, which means a new Piri DID and a full
re-onboarding at central. Ingot's `did:web` is derived from the region label and the content domain,
both of which central holds, so a rebuilt node publishes a new key under the same DID and central's
delegation to it survives. Dev takes no backups, by decision.

## Before production

Two things this repository should have before a node carries anything that matters.

**A backup strategy.** Dev runs with none. Production needs snapshots of the control volume, OpenBao
raft snapshots off the box, or scheduled `pg_dump` — and a restore that has actually been run,
because the failure this protects against is the one where the node's identity is gone.

**Piri and Ingot reading their secrets from OpenBao.** Ingot already reads one thing from it
directly: the region key every object is encrypted under stays inside OpenBao's transit engine, and
Ingot reaches it over a unix socket. Everything else is still a file, including the Postgres DSN,
the root S3 credentials and both private keys, which is why the deploy scripts render secrets into a
tmpfs at all. RFC 21 asks for nothing secret in a plain file; a tmpfs file is still a file. With both
services able to fetch the rest of their own secrets, the rendering step goes away and so does the
tmpfs.

## Development

`tofu`, `docker`, `shellcheck`. There is nothing to build.

```sh
make check
```

That is `check-tofu`, `check-shell` and `check-compose`, which are the three jobs in
[`check.yml`](.github/workflows/check.yml); each job runs one target, so CI checks what a laptop
does.

Every OpenTofu root is OpenTofu-only, enforced by a `versions.tf` that no Terraform release
satisfies. Running `terraform` in one of these directories stops at that constraint rather than
writing a state file OpenTofu then refuses to read.

### Dependency updates

Dependabot opens the pull requests, `.github/dependabot.yml` says which and how often, and
[`auto-merge-dependabot.yml`](.github/workflows/auto-merge-dependabot.yml) merges the ones that are
minor or patch bumps. The merge is squashed and armed through `fil-forge-bot`, so `main` moves only
after `tofu`, `shell` and `compose` have passed, and the nodes pull it on the next reconcile like
any other merge.

A major bump stays open for someone to read. So does a group whose highest change is a major, and so
does any Dependabot branch that carries a commit Dependabot did not write.

Dependabot rebases its pull requests in place, and the workflow runs again on each new head, so a
branch that stops qualifying also loses the auto-merge it was given earlier. Each auto-merge is
bound to the head the workflow inspected, which is what stops a head that arrives mid-run from
merging on the previous head's decision.

The container images are outside all of this, and no ecosystem reads them. Piri and Ingot have a
mechanism of their own: each dispatches its new digest here when it publishes, which is
[how a change reaches a node](#how-a-change-reaches-a-node) above. The platform images in
`nodes/dev/platform/versions.env` stay on mutable tags and are a hand edit.

## Related

- [infra-central](https://github.com/fil-forge/infra-central) — the services a node registers with,
  and the OpenBao it unseals against
- [smelt](https://github.com/fil-forge/smelt) — the single-VM staging deployment these Compose files
  come from
- [piri](https://github.com/fil-forge/piri), [ingot](https://github.com/fil-forge/ingot) — the two
  services a node exists to run
- [docs/decisions/2026-08-initial-design.md](docs/decisions/2026-08-initial-design.md) — why the node
  is shaped this way
