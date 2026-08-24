# Initial design of the FilOne Appliance dev node

A FilOne Appliance is the regional half of the Forge network: one Piri storage node and one Ingot S3
gateway, plus the dependencies they need to run unattended. This document records the choices behind
the first one: a dev node in `us-east-2`, paired with infra-central's dev stage.

## Where the node sits

The appliance runs Docker Compose on a single EC2 VM described by OpenTofu. Central services run on
ECS/Fargate in infra-central; an appliance is deliberately not that. A region's node is one box with
directly attached disks, it holds a Filecoin identity that must survive a redeploy, and its operator
may eventually be a third party who is not going to run Fargate. A VM and Compose is the smallest
thing that satisfies all three.

The AWS resources this needs are an EC2 instance, EBS volumes, an Elastic IP, a security group,
Route53 records and an IAM role. No ECS, no load balancer, no VPC of its own.

## Account, region and state

The node lives in **filone-sandbox (654654381893)**, the same AWS account as infra-central's dev
stage, in **us-east-2**.

OpenTofu state goes in **`forge-nodes-tfstate-654654381893`**, one bucket for every node in the
account, created by a bootstrap root applied by hand. This mirrors infra-central: state files are
small and namespaced by key. The account id in the name says which account's state the bucket holds,
which is the thing an operator wants to know before running anything.

The repository copies infra-central's OpenTofu conventions wholesale — `versions.tofu` with the S3
backend and `use_lockfile = true`, a `versions.tf` pinned to `< 0.0.0` so the HashiCorp binary
cannot touch OpenTofu state, `allowed_account_ids` on every provider, and `modules/shared/constants`
for values more than one root has to agree on. Two repositories with the same conventions are one
thing to learn.

## The machine

**`t4g.large`** — 2 vCPU, 8 GB, ARM Graviton — running the latest Ubuntu Server LTS for arm64,
24.04 at the time of writing. Burstable instances stall when they run out of CPU credits, and a node
that stalls mid-proof misses a proving window, so the instance runs in **unlimited credit mode** and
pays for the overage instead.

The host sets itself up on first boot. cloud-init, Canonical's first-boot service preinstalled in
every Ubuntu AMI, runs a bootstrap script rendered by OpenTofu exactly once: it installs Docker,
mounts the durable volumes, clones this repository and installs the systemd units. It creates no
secret and starts no service; that work belongs to the provision and deploy scripts, which can
re-run.

Docker and Compose come from Ubuntu's own archive (`docker.io`, `docker-compose-v2`). Ubuntu 24.04
(codenamed noble) ships Compose 2.24 or newer, which covers the `start_interval` healthchecks the
Compose files use. No third-party apt repository is added to the host.

### Two Compose projects

Everything the node runs is two Compose projects. `platform` holds OpenBao, Postgres, Caddy and
Grafana Alloy. `apps` holds Piri and Ingot. They join a shared external Docker network, `filone`,
created once by the bootstrap script, so neither project owns it.

This split makes it easy to reuse the same mechanism to deploy nodes to environments where
the dependencies are provided and managed differently, e.g. by the node operator.

### Three volumes with different lifetimes

| Volume            | Size        | Holds                                                    | On destroy        |
| ----------------- | ----------- | -------------------------------------------------------- | ----------------- |
| Root              | AMI default | OS, packages, the git checkout                           | Goes with the VM  |
| **Control plane** | 50 GB gp3   | Postgres data, OpenBao raft, Caddy certs, rendered state | `prevent_destroy` |
| **Data plane**    | 500 GB gp3  | Piri blobs, Ingot spool and LSM segments                 | `prevent_destroy` |

Both data volumes are encrypted, carry `prevent_destroy`, and are mounted by cloud-init behind a
format-once guard so a reattach never reformats a volume that already has a
filesystem.

The control plane is a volume of its own rather than a directory on the root filesystem, and that is
the whole point of the layout: it makes the VM disposable. Terminating and replacing the instance
loses nothing, because everything that cannot be recreated — the node's identity, its Postgres
databases, its issued certificates — is on a volume that outlives it.

## Names and addresses

Piri answers at **`piri.dev.forge-sandbox.fil.one`** and Ingot at
**`ingot.dev.forge-sandbox.fil.one`**, as A records in the existing `forge-sandbox.fil.one` Route53
zone, pointed at the node's Elastic IP. The zone is in the same account, so the records are ordinary
resources in the node's own root module.

There is one Piri per region. The service is called `piri`, its key is `piri.pem`, its delegation is
the piri proof. smelt's `piri-0` suffix, which anticipated several nodes per box, is not carried
over into the dev instance. We can explore multi-piri setup in the future.

### The region label is `us-east-9`

Ingot presents an S3 API, and S3 clients sign requests with a region. The production naming scheme
gives each appliance a virtual region name that is deliberately not a real AWS region, so nobody
mistakes a Forge endpoint for an AWS one and no client's region-guessing heuristics accidentally
work. The dev node is **`us-east-9`**.

This string has to be identical in three places or requests fail in ways that do not name the cause:
Ingot's `region:` config key, hilt's `provider add <did> us-east-9`, and the `AWS_REGION` a client
signs with.

## Secrets

Every secret the node holds lives in a **local OpenBao**, transit-sealed by the central OpenBao at
`ssm.dev.forge-sandbox.fil.one`. This is [RFC 21]'s model, and the reason for it is the kill lever:
central can revoke a node's ability to unseal, and the next restart of that node comes back sealed
and useless.

### Storage is raft on the control volume

OpenBao stores in raft on the control-plane volume. The alternative — the Postgres backend, matching
infra-central — creates a circular dependency on a VM: OpenBao must be up before anything else can
read a secret, but Postgres's own credentials are secrets, so Postgres would have to be up first. It
also puts the root of trust in the same blast radius as the service databases. infra-central chose
Postgres because Fargate has no durable local disk; a VM does, so the reason does not carry over.

### Unsealing uses a scoped periodic token

The central `transit/` mount stays as it is. OpenBao mounts cannot nest, so per-node grouping lives
in key names rather than sub-paths: one key per node, purpose-prefixed and named by region label —
`appliance-unseal-us-east-9`, at `transit/keys/appliance-unseal-us-east-9`. The node's policy grants
`update` on exactly two paths, `transit/encrypt/appliance-unseal-us-east-9` and
`transit/decrypt/appliance-unseal-us-east-9`, so a stolen node token unseals that node and does
nothing else.

The node authenticates with an **orphan periodic token, CIDR-bound to its Elastic IP**. Orphan, so
revoking the operator's own token does not cascade into the node; periodic, so it renews forever
without an expiry cliff; CIDR-bound, so the token is worthless anywhere but on that node. It can
only be minted after the apply that allocates the EIP, though the key and the policy can be prepared
at any time. The operator delivers it once, into a root-only `0400` file, and a systemd timer renews
it from then on.

Two alternatives were considered. Wrapped enrollment tokens add a single-use exchange that has to be
delivered on exactly the same channel as the token itself, which buys nothing at one node. AWS IAM
auth removes the shared secret entirely, but it binds the node's identity to an AWS instance profile
— a poor fit for appliances that will eventually run outside AWS.

### Secrets reach Piri and Ingot as rendered files

Piri and Ingot read their configuration from files, including the secrets in it: Ingot's YAML embeds
a Postgres DSN and root S3 credentials, and both read a private key from a path. Neither can be
handed a secret any other way today.

So the deploy scripts read the local OpenBao and render env files, Ingot's YAML and the key files
into **`/run/filone/secrets`**, a root-only tmpfs mounted read-only into the containers. Rendering
happens on every deploy; services restart only when the rendered content actually changed, compared
by hash. Nothing secret is written to a disk that survives a reboot.

[RFC 21] says nothing secret sits in a plain file, and a tmpfs file is still a file. This is a
concession to what Piri and Ingot can consume, not a preference, and it is listed in the README as
work to do before production: teach both services to read their secrets from OpenBao directly.

## Keys are generated on the node

Provisioning generates the node's Ed25519 identities (Piri, Ingot), the Piri owner wallet, and every
password directly into the local OpenBao. **No private key ever leaves the box**, and no private key
is ever on an operator's laptop or in OpenTofu state.

The accepted cost: the control-plane volume is the only copy of the node's identity. Lose it and the
node is a new node — new DIDs, full re-onboarding at central.

Tooling is three single-purpose binaries and no build toolchain on the host. `ucantool` generates
the Ed25519 identities and signs the Piri delegation to sprue. `cast wallet new` generates the EVM
owner wallet — a single binary extracted from a pinned Foundry release, not the whole toolchain.
`openssl rand` generates passwords. cloud-init installs `ucantool` and `cast`, pinned and
checksum-verified; `openssl` ships with Ubuntu.

The operator supplies exactly three secrets by hand: the OpenBao seal token, the chain.love access
token, and the Grafana Cloud push token.

## Chain access

There is **no local Lotus node**. A synced Lotus needs 32 GB of RAM and a disk that grows by 38 GB a
day, which is an order of magnitude more machine than the appliance otherwise needs. The node uses
**chain.love's free tier**, defaulting to `wss://calibration.filecoin.chain.love/ws/rpc/v2` and
configurable per node, so a node with its own Lotus or a different provider changes one variable.

The access token is a secret, sent as an `Authorization: Bearer` header, and Piri sends it itself.
`pdp.lotus_auth_token` takes the raw token and Piri prepends the scheme on both clients that dial
the endpoint, the go-ethereum one and the Lotus full-node one.

The node passes it as `PIRI_PDP_LOTUS_AUTH_TOKEN` in the container environment rather than writing
it into Piri's config. That setting has no CLI flag, for the reason a token on a command line is a
bad idea, and the environment keeps it off the data volume too: `piri init` writes the config it
generates to disk and echoes it to stdout, where Alloy would ship it to Grafana Cloud, and the token
is not among the fields it copies.

## Reaching the box

**SSM Session Manager only.** There is no inbound port 22, no bastion and no SSH key to lose. The
security group allows 80 and 443 inbound and nothing else. IMDSv2 is required, and the instance
profile carries `AmazonSSMManagedInstanceCore` and nothing else — the node's authority comes from
its OpenBao token, not from its position in an AWS account.

## TLS

Caddy obtains and renews certificates automatically over ACME, using HTTP-01 and TLS-ALPN-01 on the
two public hostnames, which is why both 80 and 443 are open. Certificates live on the control-plane
volume, so a rebuilt VM does not re-issue and does not spend rate limit.

DNS-01 would remove the need for port 80 but requires a Route53 credential on the node and a Caddy
built with the plugin (`xcaddy`). Neither is worth it for two hostnames that are already publicly
reachable.

## Deploys reconcile from git

A **systemd timer runs every five minutes**, fetches this repository and resets to `origin/main`.
Node state is its directory in git: to change a node, merge a commit.

The timer is systemd rather than cron for the ordinary reasons — the unit is version-controlled next
to the code it runs, failures land in the journal, and `systemctl list-timers` answers when it last
ran and when it runs next.

Reconcile compares the old and new commits and deploys only what changed: platform files trigger a
platform deploy, apps files trigger an apps deploy, and a commit touching neither does nothing. Each
successful pass stamps `deploy_last_success_timestamp`, which Alloy ships to Grafana Cloud, where a
deadman alert fires when the node stops reporting at all — the failure mode a per-deploy alert
cannot see.

### The proving gate is on in dev

An apps deploy waits for Piri's proving window before restarting Piri. `piri status upgrade-check`
answers this directly: exit 0 is safe, exit 1 is proving or in an unproven challenge window, exit 2
is unable to tell.

Dev could skip the gate, and running it here is the point: the gate is the mechanism that keeps a
production node from failing a proof for an image bump, and a mechanism that only runs in production
is a mechanism nobody has tested.

## Per-node directories, not shared templates

Each node owns its Compose files and its templates, under `nodes/<node>/`. A change is made on one
node, watched, and copied to the next.

The alternative — one shared stack parameterized per node — removes the copying but makes every
node's configuration change at the same instant, which is the failure this layout exists to prevent.
Rendering configuration in CI has the same problem and adds a build step between a commit and what
the node runs. The tool that copies a verified change from one node to the next is work for when
there is more than one node; today the copy is a diff between two directories.

## Telemetry

Grafana Alloy runs as a platform service and ships journald, Docker logs and node metrics to Grafana
Cloud over a push-only token held in OpenBao. Piri's own OTEL export to the Forge collector is
untouched and unrelated: that carries application traces to the central collector, this carries
host and container health to a place an operator can page from.

## No backups in dev

The dev node takes no backups at all. Its data is disposable and re-onboarding is a documented
procedure rather than a disaster.

The consequence, stated plainly: lose the control-plane volume and the node's identity is gone,
which means new DIDs and a full re-onboarding at central. The README carries this as work to do
before production — DLM snapshots of the control volume, OpenBao raft snapshots to S3, or scheduled
`pg_dump`, and a restore that has actually been run.

## Payments stay central

The payer wallet lives in infra-central and stays there. The node's Piri configuration receives
`payer_address` and the signing-service URL from the central dev stage, and funding remains
`make fund-payer STAGE=dev` in that repository. An appliance signs proofs; it does not hold the
money.

## Nothing needs a credential to fetch

The `fil-forge/infra-nodes` repository and the `ghcr.io/fil-forge/piri` and `ghcr.io/fil-forge/ingot`
images are all readable anonymously, verified without credentials. So the node clones and pulls with
no git or registry secret at all, which is one less credential to deliver, rotate and revoke. If
either becomes private, a read-only credential lands in the local OpenBao like every other secret.

## Work that lands in other repositories

Three things this node needs are built elsewhere, and the node cannot finish bring-up without them.

**The central transit key** — `appliance-unseal-us-east-9`, its encrypt/decrypt policy, and the
token-minting path — is created in **fil-forge/infra-central** on the existing `transit/` mount.
Without it OpenBao on the node cannot unseal, which blocks everything.

**The onboarding Lambda**, also in **fil-forge/infra-central**. Onboarding an appliance takes three
writes into central state — the node's DID onto the delegator's allow list, `provider register` plus
a weight against sprue, and `provider add <did> us-east-9` against hilt — and returns one proof, the
hilt→ingot S3 delegation, which can only be issued once ingot's `did:key` exists. None of it is
configuration, so no apply creates it, and there is no shell on a Fargate task to run the admin CLIs
in. The Lambda takes the node's two DIDs, its public URL and its Piri proof, performs the writes and
returns the proof. This repository ships the client that calls it. Until it exists, the runbook's
manual fallback is the only path, and end-to-end bring-up is not possible without an operator doing
the writes by hand.

**Release binaries for ucantool**, in **fil-forge/ucantool**: static linux arm64 and amd64 builds
published on GitHub releases, so cloud-init installs a pinned, checksum-verified binary instead of
compiling Go on the node. That repository publishes no binaries today.

`ucantool` also has no way to print the DID of an existing PEM — `identity generate` prints the DID
of the key it just made, and nothing reads one back. Provisioning works around this by writing each
DID into OpenBao beside its key at generation time, so a re-run reads the DID rather than deriving
it. A `ucantool identity did <file>` subcommand would remove the workaround.

[RFC 21]: https://github.com/fil-one/RFC/pull/21
