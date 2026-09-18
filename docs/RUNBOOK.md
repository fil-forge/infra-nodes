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

### The eu-central-3 staging appliance on Servers.com

The staging appliance is not an EC2 node. Its host owns Lotus, Caddy and Alloy,
and FilOne must leave them intact. Its checkout is `/root/fil-one/infra-nodes`; its
control and data directories are `/mnt/data/fil-one/control` and
`/mnt/data/fil-one/data`.

Apply the DNS-only root and confirm both names resolve to `23.83.66.244`:

```sh
tofu -chdir=terraform/envs/staging/eu-central-3 init
tofu -chdir=terraform/envs/staging/eu-central-3 apply
dig +short piri-0.staging.fil-forge.com
dig +short s3.eu-central-3.staging.filonecontent.com
```

The host-owned Caddy service needs public TCP 80 for ACME challenges and TCP
443 for HTTPS. Check the existing UFW policy and add these rules only if an
equivalent public rule is absent:

```sh
ufw status numbered
ufw allow 80/tcp comment 'Host Caddy HTTP and ACME'
ufw allow 443/tcp comment 'Host Caddy HTTPS'
```

Check out this repository at `/root/fil-one/infra-nodes`, then run:

```sh
cd /root/fil-one/infra-nodes
scripts/host/bootstrap-staging-eu-central-3.sh
```

Bootstrap creates only FilOne directories, tmpfs paths, the shared Docker
network, node config, systemd units, the Caddy import and the two FilOne UFW
rules. The `filone` network uses the fixed `172.18.0.0/16` subnet. Bootstrap
stops if an existing network with that name uses another subnet. It validates
the combined host Caddy configuration before reloading `caddy-guppy`.

The import it appends to `/root/storacha/caddy/Caddyfile` is an absolute path
into the checkout, so it names this node's directory under `nodes/`. A node
directory that moves has to be followed there in the same window:

```sh
grep -n 'infra-nodes/nodes' /root/storacha/caddy/Caddyfile
caddy validate --config /root/storacha/caddy/Caddyfile --adapter caddyfile
```

Caddy holds its running configuration in memory, so an import pointing at a
path that no longer exists costs nothing until something reloads. The next
`caddy validate` fails, and a `caddy-guppy` restart fails outright, which takes
down every site on the host rather than the appliance's two.

Confirm all three source-subnet rules are present after bootstrap:

```sh
ufw allow from 172.18.0.0/16 to any port 443 proto tcp \
  comment 'FilOne Docker to host Caddy'
ufw allow from 172.18.0.0/16 to any port 1234 proto tcp \
  comment 'FilOne Docker to host Lotus RPC'
ufw allow from 172.18.0.0/16 to any port 4318 proto tcp \
  comment 'FilOne Docker to host Alloy OTLP'
ufw status numbered
```

The three rules let Piri call its public Ingot URL, the host-owned Lotus RPC,
and the host Alloy's OTLP receiver. Do not allow TCP 1234 or 4318 from the
public internet: the receiver is unauthenticated, and the source-subnet rule is
what keeps it to the Docker bridge. Remove old FilOne rules tied to `docker0`
or another Docker bridge after confirming these source-subnet rules.

Confirm that a container can call Lotus with a one-shot JSON-RPC request:

```sh
docker run --rm --network filone \
  --add-host host.docker.internal:host-gateway curlimages/curl \
  --fail --show-error --max-time 10 \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"Filecoin.Version","params":[],"id":1}' \
  http://host.docker.internal:1234/rpc/v1
```

The response contains the Lotus version. Do not use `curl ws://…` for this
check: a WebSocket stays open after connecting, so curl waits for the server to
close it.

Confirm the same network can reach the host-owned Caddy listener:

```sh
docker run --rm --network filone \
  --add-host host.docker.internal:host-gateway curlimages/curl \
  --fail --show-error --max-time 10 \
  --connect-to s3.eu-central-3.staging.filonecontent.com:443:host.docker.internal:443 \
  https://s3.eu-central-3.staging.filonecontent.com/health
```

The host-owned Alloy ships the FilOne container logs and the host's metrics, and
its configuration is maintained outside this repository. The appliance's output
needs the same labels the dev node's Alloy attaches, so that one Grafana query
selects a service across nodes: `node="staging/eu-central-3"`, `region="eu-central-3"`,
`appliance="staging-eu-central-3"`, and a `service_name` of the form
`appliance-staging-eu-central-3-<service>`.

The same Alloy also ships telemetry for unrelated workloads on that host and for
remote scrape targets. The `appliance` label goes on the `prometheus.remote_write`
component as `external_labels`, so every series from that machine carries it.
The other labels belong on the FilOne components, and every rule below matches
the Compose project, so those other workloads keep their own service names.

Add the following rules to the existing Docker log relabel rules, after any
generic `service_name` rule, and pass those rules to the existing
`loki.source.docker` component's `relabel_rules` argument. Rules applied only to
discovery targets do not reach log entries:

```alloy
rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project", "__meta_docker_container_label_com_docker_compose_service"]
    separator     = ";"
    regex         = "filone-(?:apps|platform);(.+)"
    replacement   = "appliance-staging-eu-central-3-$1"
    target_label  = "service_name"
}

rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project"]
    regex         = "filone-(?:apps|platform)"
    replacement   = "staging/eu-central-3"
    target_label  = "node"
}

rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project"]
    regex         = "filone-(?:apps|platform)"
    replacement   = "eu-central-3"
    target_label  = "region"
}

rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project"]
    regex         = "filone-(?:apps|platform)"
    replacement   = "staging-eu-central-3"
    target_label  = "appliance"
}
```

The FilOne host metrics come from their own `prometheus.exporter.unix` scrape.
Route that scrape through a `prometheus.relabel` component that sets
`service_name="appliance-staging-eu-central-3-host"`, `node`, `region` and
`instance="staging/eu-central-3"` on every series, as `nodes/dev/platform/config/alloy/config.alloy`
does for dev. Route the cAdvisor scrape through a `prometheus.relabel` component
with the rules above; on cAdvisor series the Compose labels arrive as
`container_label_com_docker_compose_project` and
`container_label_com_docker_compose_service`. Give the reconcile journal source
the same `service_name`, `node`, `region` and `appliance` as static labels, plus the shared
journal relabel rules so the unit lands on its own label.

The host Caddy's runtime log is `/root/storacha/logs/caddy/caddy.log`. Caddy writes and rolls
that file itself, through a `log` block in the global options of `/root/storacha/caddy/Caddyfile`,
the same way the host's access logs roll:

```caddyfile
log {
    output file /root/storacha/logs/caddy/caddy.log {
        roll_size 100mb
        roll_keep 5
    }
}
```

The `caddy-guppy` unit sends stdout and stderr to the journal, through a drop-in at
`/etc/systemd/system/caddy-guppy.service.d/output.conf` with `StandardOutput=journal` and
`StandardError=journal`, so the only lines that land there are the ones Caddy prints before its
logger exists, such as a Caddyfile that fails to parse. The whole-journal source the host Alloy
already runs ships those under `unit="caddy-guppy.service"`. The same drop-in sets
`Environment=HOME=/root`: the unit runs as root without `User=`, so systemd gives it no `HOME`,
and Caddy then warns on every start and keeps its autosave and instance id under `./caddy` in the
working directory, which is `/`. A unit change needs `systemctl daemon-reload` and a restart of
`caddy-guppy`, which interrupts every site on the host for a second or two.

Tail the file with a source carrying the four labels every appliance stream shares, `service_name`,
`node`, `region` and `appliance`, so `{service_name=~"appliance-.*-caddy"}` selects Caddy on every
node. The host's own `hostname` and `service` labels go on too; `stream` and `container` do not
apply to a file. Runtime entries name no site,
so this stream is every site the host Caddy serves:

```alloy
local.file_match "host_caddy" {
  path_targets = [{
    __path__     = "/root/storacha/logs/caddy/caddy.log",
    hostname     = "curio",
    service      = "caddy",
    service_name = "appliance-staging-eu-central-3-caddy",
    node         = "staging/eu-central-3",
    region       = "eu-central-3",
    appliance    = "staging-eu-central-3",
  }]
}

loki.source.file "host_caddy" {
  targets    = local.file_match.host_caddy.targets
  forward_to = [loki.write.grafanacloud.receiver]
}
```

The file source follows Caddy's roll, and it stamps each line with the time it read it, which is
within a second of the line's own `ts` field except for whatever backlog exists when Alloy starts.

The host Caddy answers the appliance's public requests, so its request metrics are the
appliance's error rate, and they ship through the same Alloy. Caddy records per-request metrics
only when the global `metrics` option is on, and the `host` label that tells the appliance's two
sites apart from the host's other sites needs `per_host`, which arrived in Caddy 2.9. The host runs
2.9.1; `caddy build-info` says so, since this build answers `caddy version` with `unknown`. Add to
the global options block of `/root/storacha/caddy/Caddyfile`, next to the `log` block above, then
run `reload-staging-host-caddy.sh`. A reload is enough; both options live in the HTTP app config.

```caddyfile
metrics {
    per_host
}
servers :443 {
    name public
}
```

Caddy 2.9.1 records every Host header it sees as its own label value, and port 80 answers any
name a scanner sends, so the set Caddy holds grows over time. Newer releases fold unknown names
into `_other`. The scrape below keeps only the appliance's two hostnames, plus the series that
carry no host at all, so nothing from the host's other sites or from scanners reaches Grafana. On
the host, `curl -s localhost:2019/metrics | grep -o 'host="[^"]*"' | sort -u | wc -l` counts the
names Caddy is holding; thousands is the point to upgrade it.

Caddy serves `/metrics` on its admin API at `localhost:2019`, the address the reload script already
uses. `appliance` is on the writer's `external_labels` and needs no rule.

```alloy
prometheus.scrape "host_caddy" {
  targets         = [{__address__ = "127.0.0.1:2019"}]
  job_name        = "caddy"
  scrape_interval = "60s"
  forward_to      = [prometheus.relabel.host_caddy.receiver]
}

prometheus.relabel "host_caddy" {
  forward_to = [prometheus.remote_write.grafanacloud.receiver]

  // The host Caddy records every Host header it sees. Only the appliance's
  // two sites ship, plus the series with no host label at all.
  rule {
    source_labels = ["host"]
    regex         = "|piri-0\\.staging\\.fil-forge\\.com|s3\\.eu-central-3\\.staging\\.filonecontent\\.com"
    action        = "keep"
  }
  rule {
    target_label = "service_name"
    replacement  = "appliance-staging-eu-central-3-caddy"
  }
  rule {
    target_label = "node"
    replacement  = "staging/eu-central-3"
  }
  rule {
    target_label = "region"
    replacement  = "eu-central-3"
  }
  rule {
    target_label = "instance"
    replacement  = "staging/eu-central-3"
  }
}
```

Piri's own application metrics — its job queues, its IPNI advertisement backlog, HTTP latency, the
free space behind its data directory and its build — arrive by push rather than scrape: Piri
exposes no `/metrics` endpoint and exports OTLP instead. Its PDP proving is not instrumented, so
nothing about proving arrives here. The host Alloy needs a receiver for them, and it has to listen where a
container can reach it. `0.0.0.0:4318` does that; the Docker bridge has no route to a listener bound
to loopback. Everything else on this host that Piri reaches goes the same way, through
`host.docker.internal`, which the apps project maps to the host gateway.

The receiver is unauthenticated, so the host firewall is what keeps it to the Docker bridge. UFW
denies incoming by default and the bootstrap script opens 4318 to `172.18.0.0/16` alongside 443 and
1234; on a host bootstrapped before that rule existed, add it by hand or Piri's publishes are
refused even once Alloy is listening. Check the bind address with `ss -lntp | grep 4318` and the
rule with `ufw status numbered`.

```alloy
otelcol.receiver.otlp "filone_apps" {
  http {
    endpoint = "0.0.0.0:4318"
  }

  output {
    metrics = [otelcol.exporter.prometheus.filone_apps.input]
  }
}

// service.name becomes `job`, service.instance.id becomes `instance`, and the
// remaining resource attributes are carried on a `target_info` series that a
// query joins on those two labels. Piri's version and node DID are read there.
otelcol.exporter.prometheus "filone_apps" {
  forward_to = [prometheus.relabel.filone_apps.receiver]
}

prometheus.relabel "filone_apps" {
  forward_to = [prometheus.remote_write.grafanacloud.receiver]

  // The same service_name the container logs carry, so Piri's logs and its
  // metrics select under one name.
  rule {
    source_labels = ["job"]
    regex         = "(.+)"
    replacement   = "appliance-staging-eu-central-3-$1"
    target_label  = "service_name"
  }
  rule {
    target_label = "node"
    replacement  = "staging/eu-central-3"
  }
  rule {
    target_label = "region"
    replacement  = "eu-central-3"
  }
  // instance arrives as the node's DID, where every other series from this
  // host carries the node name. Overwriting it on the series and on
  // target_info alike keeps the join between them working.
  rule {
    target_label = "instance"
    replacement  = "staging/eu-central-3"
  }
}
```

Only metrics are wired: Piri emits spans but samples none of its own, and there is no trace backend
to forward them to.

This receiver has to exist before the apps project deploys a Piri that points at it. It does not
have to exist first for safety — a Piri whose collector refuses the connection logs one warning
every five minutes and serves normally — but until it does, no application metric arrives.

Validate the configuration, then restart Alloy with `systemctl restart alloy`. A
reload is not enough for the log labels: on Alloy v1.17 the Docker log source
keeps its running tailers, and their label sets, across a configuration reload,
so entries keep arriving with the old labels. After the restart each tailer
starts without a saved position and re-ships the container's retained Docker log
once under the new labels. Once the FilOne containers run, `{service_name="appliance-staging-eu-central-3-piri"}`
in Loki shows Piri's entries.

At infra-central, confirm `eu-central-3` is in `appliance_regions`, get the
staging `wallet_addresses` payer address and commit it to
`nodes/staging/eu-central-3/node.env`.
Mint a wrapping token with `STAGE=staging`, `REGION=eu-central-3` and
`NODE_IP=23.83.66.244`. On the host run `provision-platform.sh`, saving the
OpenBao recovery key and root token, then provide the wrapping token. Staging
uses its local unauthenticated Lotus RPC and the host-owned Alloy service, so it
does not ask for a Chain.Love or Grafana token.

Run `onboarding-request.sh`, fund its printed Piri owner wallet with
Calibration testnet FIL, and send its DID, URL and proof to infra-central. Run
`onboard-appliance` there for `staging/eu-central-3`, install its returned
Ingot proof with `store-hilt-proof.sh`, then run `provision-apps.sh`. Enable
both FilOne timers and check public Piri, Ingot, the status document and an
OpenBao restart/unseal. Finish with:

```sh
scripts/ci/smoke-test.sh staging/eu-central-3
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

Those four lines are per node, and a node whose host already runs Alloy leaves all four out. The
staging appliance is such a node: `nodes/staging/eu-central-3/node.env` has no telemetry block,
and the host
scripts then neither ask for a Grafana push token nor render an Alloy config. It is all four or
none. A node.env that sets some of them stops the deploy, because a node missing one id would
otherwise deploy green and ship nothing.

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
cat /etc/fil-one/bootstrap-complete     # a timestamp; absent means bootstrap died
tail -50 /var/log/filone-bootstrap.log
findmnt /mnt/fil-one/control
findmnt /mnt/fil-one/data
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

In an SSM session on the node, as root (`sudo -i`), in the checkout at `/opt/fil-one/infra-nodes`.
The rest of the bring-up runs in this shell.

```sh
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
docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$(cat /etc/fil-one/bao-token)" \
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
`/readyz`, Ingot answers `/health`, both hostnames serve over HTTPS with issued certificates, and
Caddy serves the node status document.

It then installs the systemd units from the checkout, so the timers below exist whatever revision
cloud-init bootstrapped the box from.

### 6. The timers

```sh
systemctl enable --now filone-reconcile.timer
systemctl enable --now filone-seal-token-renew.timer
systemctl list-timers | grep filone
```

From here, changes reach the node by being merged. The node tracks whatever `FILONE_GIT_REF` in
`/etc/fil-one/node.conf` names, which cloud-init writes as `main`.

## Day-to-day operations

Commands in this section run from the infra-nodes checkout: `/opt/fil-one/infra-nodes` on the
cloud nodes and `/root/fil-one/infra-nodes` on staging, the `FILONE_CHECKOUT` value in
`/etc/fil-one/node.conf`.

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
sudo scripts/host/reconcile.sh
```

**Test a branch before it merges.** Point the node at it and let the next pass pick it up:

```sh
sed -i 's|^FILONE_GIT_REF=.*|FILONE_GIT_REF=my-branch|' /etc/fil-one/node.conf
```

Set it back to `main` before the branch is deleted. A node tracking a ref that no longer exists
fails the reset, so reconcile stops and the deploy deadman goes stale.

`/etc/fil-one/node.conf` is the only statement of the ref. Reconcile reads it on every pass, so an
environment variable passed to a single run would be undone five minutes later. The timer units read
`FILONE_CHECKOUT` from the same file, which is how one unit file serves a node whose checkout is
under `/opt` and one whose checkout is under `/root`.

**Upgrade ucantool or cast.** Edit the pins in `nodes/dev/node.env`, merge, then run
`sudo scripts/host/install-tools.sh` on the node. Reconcile does not run
the install — only key generation uses these tools — so the new binary lands when the script runs,
not when the commit merges.

**Rotate a secret.** Write the new value into OpenBao, then run `deploy-platform.sh` or
`deploy-apps.sh`. Rendering compares by content, so only the services whose files changed restart.

The unseal token is not in OpenBao. A new one written to `/etc/fil-one/seal-token` applies on the
next platform deploy, which recreates OpenBao inside the proving-window gate with the apps stopped.
That works while the old token still unseals. A node whose OpenBao is already sealed fails the
deploy before it reaches the gate; the way back is `provision-platform.sh` with a fresh wrapping
token.

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

In Grafana Explore, select the Loki datasource and query `{appliance="dev-us-east-9"}` for
everything the node ships, or `{node="dev"}` for one box. Docker logs carry
`service_name="appliance-<stage>-<region>-<compose-service>"`, so Piri on dev is
`{service_name="appliance-dev-us-east-9-piri"}`, Piri on staging is
`{service_name="appliance-staging-eu-central-3-piri"}`, and Ingot ends in `-ingot`.

Host metrics sit in the Prometheus datasource under the same `appliance`, `node` and `region` labels, with
`service_name="appliance-<stage>-<region>-host"` and `instance` set to the node name, so
`node_filesystem_avail_bytes{node="dev"}` is the dev appliance's free space. On dev the series
come from the Alloy container's node exporter; on staging they come from the host's own exporter
and cAdvisor, so container metrics such as `container_memory_working_set_bytes` exist for staging
only. Caddy's request metrics ship from both nodes under `service_name="appliance-<stage>-<region>-caddy"`
and `job="caddy"`; [observability.md](observability.md#caddy-requests) has the 5xx queries.

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
`FILONE_GIT_REF` in `/etc/fil-one/node.conf`. The entries below cover each.

*The dev node failed its smoke test.* The node has the commit and is not serving what the commit
pins, so suspect the image. The run's log names the failing check. A check that says the deployed
revision is not in this checkout usually means the clone is behind, so `git fetch` and run it again;
if the revision is still nowhere on origin, the node is following another ref and
`FILONE_GIT_REF` in `/etc/fil-one/node.conf` says which. Rolling back is a pin bump like any other:

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
