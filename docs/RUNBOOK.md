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

That guide is the other half of steps 4 and 6 below. Whoever runs infra-central mints the unseal
token, supplies the payer address and registers the node; nothing in this repository can do any of
that, and nothing in that one can read this node's keys.

## Bringing up a node

A node's host decides how it is built. Terraform creates the dev node's EC2 host, which you then
provision over SSM. The eu-central-3 appliance is bare metal that already runs Lotus, Caddy and
Alloy; Terraform only points DNS at it. Each stage has one node today, so step 3 names both — but
hosting is what decides, not stage.

Steps 1 and 2 are the same for any node. Step 3 is where they differ. Steps 4 to 7 are one
procedure run with the values step 3 establishes.

### 1. The state bucket, once per account

```sh
cd terraform/envs/bootstrap/nonprod
```

Every node's root keeps its state in a bucket this root creates, one per AWS account, so dev and
staging, which share an account, share it. The `bootstrap/nonprod` root keeps its own state there
too, so its first apply cannot use the S3 backend. Comment out the `backend "s3"` block in
`versions.tofu`, apply against the local backend, restore the block, and migrate:

```sh
tofu init
tofu apply
# restore the backend block, then:
tofu init -migrate-state
```

Every node's root after this one is ordinary: `tofu init` and go.

### 2. The node.env values

`nodes/dev/node.env` describes the EC2 dev node and the accounts it talks to, and the values below name
those accounts rather than anything in this repository. They are set for dev. A node added later
needs its own copy of them, and the deploys in steps 5 and 6 refuse to run while any is still the
placeholder it was committed with. Set them in the checkout, commit and merge: the node resets to
`origin/main` on every reconcile pass, so an edit made on the box is gone within five minutes.

`GRAFANA_LOGS_USER` and `GRAFANA_METRICS_USER` are the Loki and Prometheus instance ids of the
Grafana Cloud stack the node ships to. Both are on the stack's details page in the Grafana Cloud
portal, on the Loki tile and the Prometheus tile, and they differ from each other. Those same two
tiles carry the push URLs, which belong in `GRAFANA_LOGS_URL` and `GRAFANA_METRICS_URL`: each names
the cluster its stack sits on, so another stack pushes elsewhere.

Traces go to the stack's Tempo, which accepts OTLP over gRPC on its own host. Its user id is
Tempo's instance id, which differs from the two above and belongs in `GRAFANA_TRACES_USER`. Without
portal access it can be read from Grafana itself: the stack's traces data source, under
**Connections -> Data sources**, shows it as the basic authentication user, and its URL names the
Tempo host. `GRAFANA_TRACES_URL` is that host and port 443, with no scheme and no path, as in
`tempo-us-central1.grafana.net:443`. OTLP over HTTP to the same host answers 404 at every path
tried, `/v1/traces`, `/tempo/v1/traces` and `/otlp/v1/traces` alike, and the exporter drops each
batch as `Unimplemented`.

Those six lines are per node, and a node whose host already runs Alloy leaves all six out. The
staging appliance is such a node: `nodes/staging/eu-central-3/node.env` has no telemetry block,
and the host
scripts then neither ask for a Grafana push token nor render an Alloy config. It is all six or
none. A node.env that sets some of them stops the deploy, because a node missing one id would
otherwise deploy green and ship nothing.

`PAYER_ADDRESS` is the wallet the central signing service pays from for the stage the node joins.
Only the central account can read it, so ask whoever runs infra-central; their runbook says where
they get it. It is a public address, so any channel will do.

`INGOT_LOCAL_BLOB_MAX_BYTES` becomes Ingot's `local_blob_max_bytes`: one byte budget for its spool
(bodies being written or waiting for upload to Piri) and its cache (copies of bodies Piri already
holds). Every 30 seconds a sweeper evicts cached bodies, oldest first, down to 90% of it. Ingot reads
0 as no budget, and its cache then keeps every body until the disk fills, so `deploy-apps.sh`
refuses anything but a positive byte count. On the EC2 nodes Ingot has the data volume to itself,
so size the budget from that volume's filesystem:

1. Start from 90% of the filesystem's size, the most it can hold before infra-central's "Ingot
   volume free space below 10%" alert fires. The cache stays near the budget, so a budget above
   that line keeps the alert firing. The 40% free-space alert leaves this volume out.
2. Subtract the filesystem's root reserve (5% on the ext4 volumes bootstrap creates), which the
   alert counts as used.
3. Subtract the ingest rate × 30 seconds, by which usage can exceed the budget between sweeps. With
   no measured rate, use the volume's write throughput: every body lands there first.
4. Subtract room for the catalog log, `/data/segments`, which the budget does not cover. With
   Ingot's defaults it holds up to 6 shipped segments of 64 MiB per bucket, plus the open and
   unshipped ones.

What is left is the budget. It should also exceed the ingest rate × 10 minutes
(`cache_min_residency`); below that, the sweeper evicts bodies written within that window. Ingot's
README, "Local disk", has the full sizing list.

Dev: the 500 GiB data volume (`data_volume_size` in `terraform/envs/dev/terraform.tfvars`) formats
to a 491 GiB filesystem. 90% of it is 442 GiB; less the 25 GiB root reserve, 417 GiB; less gp3's
default 125 MiB/s for 30 seconds, about 4 GiB; less about 31 GiB for the catalog log: 382 GiB,
rounded down to 380 GiB, or 408021893120 bytes. That exceeds the 73 GiB that 125 MiB/s writes in ten
minutes.

A node where Ingot shares its filesystem is sized from ingest instead, so the budget does not crowd
out what else lives there. Take at least twice the peak ingest rate × 10 minutes, using the highest
median of recent valid runs on [forge-perf](https://fil-forge.github.io/forge-perf/) where the node
has not measured its own, and check it against the largest spool-plus-cache usage the node has
shown (`max_over_time(sum(ingot_local_blobs_usage_bytes{appliance="<appliance>"})[30d:5m])`). With
everything else on the filesystem and its root reserve, it should leave the filesystem below 60%
used, so the 40% free-space alert stays quiet.

Staging: Ingot's data directory is `/var/lib/fil-one/ingot`, on the host's root filesystem: 15.2 TB
(13.8 TiB) of ext4 on SSD, shared with the OS and Docker, about 1 TB of it in use on 2026-11-04. The
Piris, Postgres and OpenBao stay on the ZFS pool at `/mnt/data`. forge-perf's highest median from
its valid runs of 19 and 20 October 2026 is 3.96 GB/s, on one m9gd.16xlarge running every service;
ten minutes of that is 2.38 TB, or 2.16 TiB. Twice that is 4.33 TiB, rounded up to 5 TiB, or
5497558138880 bytes. That is over 18 times the 298 GB (278 GiB) spool-plus-cache peak of the 30 days
to 2026-10-26. With the 5% root reserve
and what was already there, it leaves the root filesystem about half used. The staging host is not
the forge-perf box, so its own rate may be lower; the budget errs on the large side.

### 3. The node's host

Everything before this step is the same for any node; everything after it is the same procedure run
with this node's own values:

| | dev | eu-central-3 |
|---|---|---|
| `STAGE` | `dev` | `staging` |
| `REGION` | `us-east-9` | `eu-central-3` |
| `NODE_IP` | the Elastic IP the apply allocated | `23.83.66.244` |
| Shell on the node | `scripts/operator/ssm-session.sh dev`, then `sudo -i` | `ssh root@23.83.66.244` |
| Checkout | `/opt/fil-one/infra-nodes` | `/root/fil-one/infra-nodes` |
| Platform services | Postgres, Caddy, Alloy | Postgres; the host owns Caddy and Alloy |
| Piris | `piri-0` to `piri-2`, each on its own EBS volume at `/mnt/fil-one/piri-<n>` | `piri-0` to `piri-2`, in `/mnt/data/fil-one/data/piri-<n>`, on loopback ports 15100 to 15102 |
| Piri hostnames | `piri-<n>.us-east-9.latest.dev.fil-forge.com` | `piri-<n>.eu-central-3.staging.fil-forge.com` |
| `provision-platform.sh` also asks for | the chain.love and Grafana Cloud tokens | the chain.love token; Alloy is the host's |

#### The dev node on EC2

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

#### The eu-central-3 staging appliance on Servers.com

The staging appliance is not an EC2 node. Its host owns Lotus, Caddy and Alloy,
and FilOne must leave them intact. Its checkout is `/root/fil-one/infra-nodes`; its
control and data directories are `/mnt/data/fil-one/control` and
`/mnt/data/fil-one/data`.

Apply the DNS-only root and confirm every name resolves to `23.83.66.244`:

```sh
tofu -chdir=terraform/envs/staging/eu-central-3 init
tofu -chdir=terraform/envs/staging/eu-central-3 apply
for n in 0 1 2; do dig +short "piri-$n.eu-central-3.staging.fil-forge.com"; done
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

Confirm both source-subnet rules are present after bootstrap:

```sh
ufw allow from 172.18.0.0/16 to any port 443 proto tcp \
  comment 'FilOne Docker to host Caddy'
ufw allow from 172.18.0.0/16 to any port 4318 proto tcp \
  comment 'FilOne Docker to host Alloy OTLP'
ufw status numbered
```

The two rules let Piri call its public Ingot URL and send telemetry to the host's Alloy. Remove old
FilOne rules tied to `docker0` or another Docker bridge after confirming these source-subnet rules.

Piri dials Chain.Love for chain RPC. Staging has its own chain.love token,
separate from dev's, in OpenBao at `external#chain_rpc_token`. The token is the bare API key, not
the endpoint URL the Chain.Love dashboard shows with it. The key accepts WebSocket connections only,
so check it with a WebSocket upgrade request. The host token goes to `docker exec` through its
environment and the chain.love token through a file descriptor, so neither appears in a command
line:

```sh
token="$(BAO_TOKEN="$(cat /etc/fil-one/bao-token)" docker exec -e BAO_ADDR=http://127.0.0.1:8200 \
  -e BAO_TOKEN filone-openbao bao kv get -mount=filone -field=chain_rpc_token external)"
curl --http1.1 -sS -i --max-time 5 \
  -H @<(printf 'Authorization: Bearer %s\n' "$token") \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  https://calibration.filecoin.chain.love/ws/rpc/v1 | head -1
unset token
```

A working key prints `HTTP/1.1 101 Switching Protocols`, followed by curl's timeout error, because
the WebSocket stays open until `--max-time` closes it. A rejected key gets a 403. A plain JSON-RPC
request over HTTPS proves nothing here: Chain.Love answers it with 403 for this key and with 200
for no key at all, since it also serves anonymous, rate-limited traffic.

Confirm the same network can reach the host-owned Caddy listener:

```sh
docker run --rm --network filone \
  --add-host host.docker.internal:host-gateway curlimages/curl \
  --fail --show-error --max-time 10 \
  --connect-to s3.eu-central-3.staging.filonecontent.com:443:host.docker.internal:443 \
  https://s3.eu-central-3.staging.filonecontent.com/health
```

A host bootstrapped while staging still used its Lotus carries a third rule, for TCP 1234, and no
chain.love token. Move it over in this order, because `deploy-apps.sh` stops when the token is
missing:

1. Store the token. `external` holds nothing else on this host, so `put` replaces nothing; check
   that first:

   ```sh
   bao_exec() {
     BAO_TOKEN="$(cat /etc/fil-one/bao-token)" docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 \
       -e BAO_TOKEN filone-openbao bao "$@"
   }
   bao_exec kv get -mount=filone external   # expect "No value found"
   read -rsp 'chain.love token: ' token; echo
   bao_exec kv put -mount=filone external chain_rpc_token=- <<<"$token"
   unset token
   ```

2. Deploy the commit that moved staging to Chain.Love with `scripts/host/deploy-apps.sh`. The same
   commit changed a comment in the base config, so each Piri re-runs `piri init` against Chain.Love
   as it restarts. They restart one at a time.
3. Confirm each Piri is healthy, that none still holds a connection to the host's Lotus, and that
   no token is left on the data disk:

   ```sh
   docker ps --filter name=filone-piri                                       # all three healthy
   ss -tn state established '( sport = :1234 )' | grep 172.18.             # expect no output
   grep -l lotus_auth_token /mnt/data/fil-one/data/piri-*/piri-config.toml   # expect no output
   ```

4. Delete the TCP 1234 rule: `ufw status numbered`, then `ufw delete <n>` for the rule commented
   `FilOne Docker to host Lotus RPC`.

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

// The Piris are one service with one instance each: piri-0, piri-1 and piri-2
// share service_name ...-piri, the name their metrics carry, and are told
// apart by instance, the service.instance.id each one reports.
rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project", "__meta_docker_container_label_com_docker_compose_service"]
    separator     = ";"
    regex         = "filone-apps;(piri)-[0-9]+"
    replacement   = "appliance-staging-eu-central-3-$1"
    target_label  = "service_name"
}

rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project", "__meta_docker_container_label_com_docker_compose_service"]
    separator     = ";"
    regex         = "filone-apps;(piri-[0-9]+)"
    replacement   = "staging/eu-central-3/$1"
    target_label  = "instance"
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
`container_label_com_docker_compose_service`.

**The cAdvisor component needs `node`, `region` and `instance` as static rules
as well**, alongside the Compose-label rules. Those rules read labels that
belong to a container, and `up` is one series per *scrape target*, not per
container, so none of them matches it. Without the static rules `up` for that
scrape arrives carrying only `appliance`, `job` and a raw `instance`:

```
up{appliance="staging-eu-central-3", instance="ff", job="cadvisor"}
```

That matters because `appliance` is `<stage>-<region>` and so cannot tell two
boxes in one region apart — `node` is the fleet's per-box identity, and anything
that cannot see it can only work per region. Normalising `instance` to
`staging/eu-central-3` matters for the same reason: the host scrape already
reports it that way, so until both agree nothing can join across the two.

```alloy
rule {
    replacement  = "staging/eu-central-3"
    target_label = "node"
}

rule {
    replacement  = "eu-central-3"
    target_label = "region"
}

rule {
    replacement  = "staging/eu-central-3"
    target_label = "instance"
}
```

A rule with a `replacement` and no `source_labels` sets the label on every
series the component sees, which is the point: the Compose-label rules above
still give each container its `service_name`, and these give the scrape's own
series — `up` included — the identity of the box they came from. The host's
other containers on that machine pick up `node` and `region` too, which is
accurate: they are on that node. They still carry no `service_name`, which is
what keeps them out of the appliance rules.

`Appliance telemetry is missing its node label`, in `infra-central`'s
`terraform/envs/grafana/alerts.tf`, fires while this is not done and goes quiet
once it is — so this does not depend on anyone remembering to check.

Give the reconcile journal source the same `service_name`, `node`, `region` and `appliance` as
static labels, plus the shared journal relabel rules so the unit lands on its own label. The OpenBao
snapshot unit gets a second source of the same shape, so the query for a failed snapshot is the
same as on dev:

```alloy
loki.source.journal "filone_openbao_snapshot" {
  matches       = "_SYSTEMD_UNIT=filone-openbao-snapshot.service"
  forward_to    = [loki.write.grafanacloud.receiver]
  relabel_rules = loki.relabel.journal.rules

  labels = {
    hostname     = "curio",
    service      = "filone-openbao-snapshot",
    service_name = "appliance-staging-eu-central-3-host",
    node         = "staging/eu-central-3",
    region       = "eu-central-3",
    appliance    = "staging-eu-central-3",
  }
}
```

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
  // sites ship, plus the series with no host label at all.
  rule {
    source_labels = ["host"]
    regex         = "|piri-[0-9]+\\.eu-central-3\\.staging\\.fil-forge\\.com|s3\\.eu-central-3\\.staging\\.filonecontent\\.com"
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

Piri's own metrics and traces also go through this Alloy, with checks of their own: [Piri's metrics
and traces in eu-central-3](#piris-metrics-and-traces-in-eu-central-3), at the end of this subsection.

Validate the configuration, then restart Alloy with `systemctl restart alloy`. A
reload is not enough for the log labels: on Alloy v1.17 the Docker log source
keeps its running tailers, and their label sets, across a configuration reload,
so entries keep arriving with the old labels. After the restart each tailer
starts without a saved position and re-ships the container's retained Docker log
once under the new labels. Once the FilOne containers run, `{service_name="appliance-staging-eu-central-3-piri"}`
in Loki shows Piri's entries.

At infra-central, confirm `eu-central-3` is in `appliance_regions` and get the staging
`wallet_addresses` payer address for this node's `PAYER_ADDRESS`.

##### Piri's metrics and traces in eu-central-3

Forge's services push their metrics and traces over OTLP/HTTP to `host.docker.internal:4318`, which
is the host's own Alloy: Piri from the `[telemetry]` section of
`nodes/staging/eu-central-3/apps/config/piri/piri-base-config.toml.tpl`, and Ingot from the
`OTEL_EXPORTER_OTLP_ENDPOINT` that `nodes/staging/eu-central-3/apps/compose.yml` sets for it. Each
reports `service.namespace="forge"`, which is what the configuration below selects them by, so a
Forge service added later needs no change here. It needs Piri at or after fil-forge/piri#146 and
Ingot at or after fil-forge/ingot#195, the first to report the namespace.

The Alloy service is configured by hand, outside this repository, so it has to be given a receiver
for Forge's services once. On a new host that is part of bring-up; on a host that is already up and
only lacks it, these steps stand on their own and nothing else in this section needs repeating.
Until it is done, Piri's pushes fail and it logs them at `WARN` from the `telemetry` logger, backing
off.

Everything below runs as root on the host, over `ssh root@23.83.66.244`. The login shell is Fish;
run `bash` first so the commands paste as written.

**1. Find the configuration Alloy runs.** The unit names it:

```sh
systemctl cat alloy
```

Look for the config path on the `ExecStart` line, or in the file an `EnvironmentFile=` line points
to (`CONFIG_FILE=` there, on a package install). A package install uses `/etc/alloy/config.alloy`,
and the commands below assume it; substitute the real path if it differs. If it is a directory
rather than a file, run each `grep` below with `-r` against the directory.

**2. Check what is already there.** Three checks, each of which normally prints nothing:

```sh
grep -n 'otelcol.receiver.otlp' /etc/alloy/config.alloy
grep -nE 'otelcol\.exporter\.otlp' /etc/alloy/config.alloy
ss -ltnp | grep -E ':431[78]\b'
```

No output from a `grep` means no match, and it exits 1; no output from `ss` means nothing listens
on 4317 or 4318. All three empty is the usual case: add the whole snippet in step 5. Otherwise:

- **A receiver is already there.** Keep it rather than adding a second. Leave the snippet's
  `otelcol.receiver.otlp` block out, send the existing receiver's metrics output to
  `otelcol.processor.batch.filone.input` as well as wherever it goes now, and route its traces
  output to `otelcol.processor.transform.filone_traces.input` instead of wherever it goes now. The
  relabel keeps only the `forge/` jobs and the transform only labels traces whose
  `service.namespace` is `forge`, so the host's other senders pass through untouched; sending traces both ways would export them twice.
- **A traces exporter to Grafana Cloud is already there.** Leave the snippet's
  `otelcol.exporter.otlp` and `otelcol.auth.basic` blocks out, point the batch processor's
  `traces` output at the existing exporter, and skip step 4.
- **Something other than Alloy holds 4318.** Stop: the receiver cannot bind, and whatever that is
  needs moving first.

**3. Confirm the firewall denies by default.** The receiver binds every interface because Forge's
services reach it through the Docker host gateway, and it takes no authentication. UFW, not the bind
address, is what keeps it off the public internet:

```sh
ufw status verbose
```

The `Default:` line has to start `deny (incoming)`. If it does not, stop and fix that first.

**4. Check the host pushes to the stack the snippet's Tempo values belong to.** The snippet writes
in one Grafana Cloud stack's Tempo endpoint and user, and authenticates with the token the host's
Alloy already pushes metrics with, which it reads from `GRAFANA_PROM_PASSWORD`. Tempo accepts it
only from an access policy on that stack with `traces:write`, so the host's metrics have to go to
the same stack. See how the host's metrics writer authenticates, without printing the password:

```sh
grep -nA12 'prometheus.remote_write "grafanacloud"' /etc/alloy/config.alloy \
  | grep -E 'username|password' | sed -E 's/(password *= *)"[^"]*"/\1"<literal>"/'
```

On this host it reads `sys.env("GRAFANA_PROM_USER")` and `sys.env("GRAFANA_PROM_PASSWORD")`. The
username is the stack's Prometheus instance id, and it is in the unit's environment file; print
only that line, since the file also holds the password:

```sh
systemctl show alloy -p EnvironmentFiles
grep -h '^GRAFANA_PROM_USER=' <each file listed above>
```

`GRAFANA_PROM_USER=475506` is that stack (it's the `GRAFANA_METRICS_USER` in `nodes/dev/node.env`),
and the snippet as written is right. If the password comes from somewhere other than
`GRAFANA_PROM_PASSWORD`, change the snippet's `password` to match. Any other username is a different
stack: the snippet's Tempo endpoint and user are wrong for it, so leave out the two
`grafanacloud_traces` blocks and the batch processor's `traces` output until that stack's Tempo
details are known.

Until that token's access policy has `traces:write`, Tempo rejects the traces with a 401 and Alloy
logs one `Exporting failed. Dropping data.` line per rejected batch; metrics are unaffected. Adding
the scope turns traces on with no second visit here.

**5. Add the snippet** to the configuration file, below what is there:

```alloy
otelcol.receiver.otlp "filone" {
  http {
    endpoint = "0.0.0.0:4318"
  }

  output {
    metrics = [otelcol.processor.batch.filone.input]
    traces  = [otelcol.processor.transform.filone_traces.input]
  }
}

// Traces stay OTLP to Grafana Cloud, so the appliance labels go on as
// resource attributes rather than through a Prometheus relabel.
otelcol.processor.transform "filone_traces" {
  error_mode = "ignore"

  trace_statements {
    context    = "resource"
    statements = [
      `set(resource.attributes["node"], "staging/eu-central-3") where resource.attributes["service.namespace"] == "forge"`,
      `set(resource.attributes["region"], "eu-central-3") where resource.attributes["service.namespace"] == "forge"`,
      `set(resource.attributes["appliance"], "staging-eu-central-3") where resource.attributes["service.namespace"] == "forge"`,
    ]
  }

  output {
    traces = [otelcol.processor.batch.filone.input]
  }
}

otelcol.processor.batch "filone" {
  output {
    metrics = [otelcol.exporter.prometheus.filone.input]
    traces  = [otelcol.exporter.otlp.grafanacloud_traces.input]
  }
}

// The stack's Tempo, over gRPC: OTLP over HTTP to this host gets a 404. Values
// from GRAFANA_TRACES_URL and GRAFANA_TRACES_USER in nodes/dev/node.env. The
// password is the host's own push token, step 4.
otelcol.exporter.otlp "grafanacloud_traces" {
  client {
    endpoint = "tempo-us-central1.grafana.net:443"
    auth     = otelcol.auth.basic.grafanacloud_traces.handler
  }
}

otelcol.auth.basic "grafanacloud_traces" {
  username = "233235"
  password = sys.env("GRAFANA_PROM_PASSWORD")
}

otelcol.exporter.prometheus "filone" {
  forward_to = [prometheus.relabel.filone_forge.receiver]
}

prometheus.relabel "filone_forge" {
  forward_to = [prometheus.remote_write.grafanacloud.receiver]

  // Only Forge's series. The conversion builds job as namespace/name, so every
  // Forge service's job starts forge/. Anything else reaching this relabel
  // through a shared receiver has its own path and must not be labelled as
  // Forge's.
  rule {
    source_labels = ["job"]
    regex         = "forge/.+"
    action        = "keep"
  }
  // Named for the service, as the log labels are: forge/piri becomes
  // appliance-staging-eu-central-3-piri.
  rule {
    source_labels = ["job"]
    regex         = "forge/(.+)"
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
  // Every Forge sender is named by the node, as every other appliance series
  // is, except Piri. The node runs several Piris, and each sets
  // service.instance.id to staging/eu-central-3/piri-<n>, so its instance is
  // kept: set aside before the overwrite and put back after it.
  rule {
    source_labels = ["job", "instance"]
    separator     = ";"
    regex         = "forge/piri;(.+)"
    replacement   = "$1"
    target_label  = "__tmp_piri_instance"
  }
  rule {
    target_label = "instance"
    replacement  = "staging/eu-central-3"
  }
  rule {
    source_labels = ["__tmp_piri_instance"]
    regex         = "(.+)"
    target_label  = "instance"
  }
  rule {
    action = "labeldrop"
    regex  = "__tmp_piri_instance"
  }
}
```

The relabel writes to `prometheus.remote_write.grafanacloud`, the name the host's existing metrics
writer has; check the file for `prometheus.remote_write` and change the name if it differs.

**6. Open 4318 to the Docker subnet.** Bootstrap adds this rule on a new host; this one was
bootstrapped before the rule existed:

```sh
ufw allow from 172.18.0.0/16 to any port 4318 proto tcp comment 'FilOne Docker to host Alloy OTLP'
```

**7. Validate, then restart.** A reload is not enough on this Alloy; the restart paragraph above
says why.

```sh
alloy validate /etc/alloy/config.alloy
systemctl restart alloy
```

`alloy validate` prints nothing when the file is valid. It does not read the environment, so it
passes even when a variable the file reads with `sys.env` is unset in the service's. Alloy then
fails its initial load, with `no password provided` for an empty password, and restarts in a loop
that takes the host's logs and metrics down too; undo the snippet to recover. After the restart, `ss -ltnp | grep 4318`
shows `alloy` listening, and `journalctl -u alloy --since '-5 min' | grep -iE 'error|filone'` shows
nothing from the new components.

**8. Check the Piris can reach it**, from inside a Piri container, through the host gateway and UFW:

```sh
docker exec filone-piri-0 wget -q -O - --header 'Content-Type: application/json' \
  --post-data '{}' http://host.docker.internal:4318/v1/metrics
```

It prints `{"partialSuccess":{}}`: an empty export, accepted. A timeout means the UFW rule is
missing; `connection refused` means Alloy is not listening on 4318.

Each service's series then arrive in Grafana under `job="forge/<service>"` (Piri's as
`job="forge/piri"`), and each service's traces under `service.name="<service>"` with
`service.namespace="forge"`; `docs/observability.md` has the queries. Ingot's series arrive under
`job="forge/ingot"`, among them the `ingot_local_blobs_*` budget metrics that infra-central alerts on.

A host set up from an earlier version of this snippet selects Forge's services by name instead: its
`where` clauses match `service.name="piri"` (and `"ingot"`), and its relabel is `filone_piri`,
keeping `job="piri"` with a fixed `service_name`. Neither configuration works across the image
change: the old one drops Piri's series once Piri reports the namespace, and the new one drops them
until it does. Traces keep arriving either way; only their `node`, `region` and `appliance` depend
on the match. So switch in two steps, validating and restarting after each as in step 7:

1. **Before promoting** Piri and Ingot images that report the namespace to this host, make the old
   configuration accept both forms. Each `where` clause becomes
   `where resource.attributes["service.namespace"] == "forge" or resource.attributes["service.name"] == "piri" or resource.attributes["service.name"] == "ingot"`,
   and in `filone_piri` the `keep` rule and the fixed `service_name` rule become:

   ```alloy
   rule {
     source_labels = ["job"]
     regex         = "piri|forge/.+"
     action        = "keep"
   }
   rule {
     source_labels = ["job"]
     regex         = "(?:forge/)?(.+)"
     replacement   = "appliance-staging-eu-central-3-$1"
     target_label  = "service_name"
   }
   ```

2. **Once both services on this host report the namespace**, replace the transform's statements and
   the relabel with the snippet in step 5, and point every `forward_to` that names
   `prometheus.relabel.filone_piri` at `prometheus.relabel.filone_forge`. On a host that reuses an
   existing receiver, that may be the host's own exporter as well as this snippet's.

Saved queries, dashboards and alerts that select `job="piri"` stop matching once Piri reports the
namespace. Change them to `job="forge/piri"`, or to `job=~"forge/.+"` for every Forge service.

### 4. The unseal token

Central mints it, and only now: the token is bound to the node's address. For the appliance that is
its host's fixed address. For dev it is the Elastic IP the apply allocated; to read it again:

```sh
tofu -chdir=terraform/envs/dev output -raw public_ip
```

Send that address to whoever runs infra-central, and they run

```sh
make mint-appliance-credentials STAGE=<stage> REGION=<region> NODE_IP=<the address>
```

What comes back to you is a **wrapping token**, not the unseal token itself. The credential stays
inside the central OpenBao until the node claims it in step 5. A node whose `node.env` sets
`FILONE_TAKES_BACKUPS=true`, as staging's does, also gets a second wrapping token, for the access
key it writes its Postgres and OpenBao backups with. Central wraps the bucket, key prefix and AWS
region with the key, so `node.env` names none of them. Each wrapping token can be spent once and
expires in 24 hours, so chat is an acceptable channel for them; a view-once 1Password link is
better.

### 5. The platform

Open a shell on the node as root, in its checkout; step 3 gives both for each node. The rest of
the bring-up runs in this shell.

```sh
scripts/host/provision-platform.sh
```

It asks for the unseal-token wrapping token, exchanges it at central for the unseal token,
initialises OpenBao, and prints **one recovery key and one root token**.
Both are printed once and stored nowhere on the node. Put both in 1Password before continuing: with
neither, the only way back into this OpenBao is to rebuild the node and re-onboard it.

It then asks for the root token back twice, to create the host token and the KV mount and then the
region key Ingot encrypts objects under. The host token is what every later deploy, reconcile pass
and OpenBao snapshot runs as. Between the two, on a node that takes backups, it runs
`provision-backups.sh`, which asks for the backup-key wrapping token, exchanges it at central,
stores the key and its target at `filone/backup-target`, and writes a small object with the key to
prove it can write there. It then uploads the first OpenBao snapshot and enables the daily snapshot
timer. A failed write stops the run with S3's reason; fix it and re-run, which skips what is already
stored. It then installs the identity tooling (ucantool and cast, pinned in the node's `node.env`);
generates the node's keys; asks for whichever operator-supplied tokens
that node needs; and starts its platform services. Step 3 says which, for each node.

A lapsed or revoked Ingot region-key token is replaced by a separate run of the same steps:

```sh
scripts/host/provision-regionkey.sh
```

It asks for the root token, enables the transit engine, creates the node's transit key (`region-us-east-9` on dev), writes the
`ingot-regionkey` policy and mints the token Ingot holds. Whatever already exists is left alone, so
on a provisioned node only the token is new, and it overwrites the old one.

The Grafana Cloud token is an access policy token scoped to the stack with `logs:write`,
`metrics:write` and `traces:write`, created under **Security -> Access Policies** in the Grafana Cloud portal. That page
needs Admin on the org, so ask whoever holds it if the page tells you to.

Certificates are issued on Caddy's first start. If the DNS records have not propagated yet, Caddy
retries and the deploy's health gate may time out; re-running `deploy-platform.sh` is safe.

### 6. Onboarding, then the apps

On the node:

```sh
scripts/host/onboarding-request.sh
```

It prints, for each Piri, its DID, its public URL and the delegation it signed with its own key, as
one `make onboard-appliance` command per Piri. Send that to whoever runs infra-central: central
runs the command once per Piri, and records each Piri DID under the region, so hilt offers all of
them to sprue. The
Ingot identity is not in it: central derives the same did:web from the stage's domain, so there is
nothing to mistype. The script prints it anyway, because the node has to be configured with the
matching string — `INGOT_DID` in `nodes/<node>/node.env`, which `deploy-apps.sh` renders into
Ingot's `identity.service_id`. Central's delegation is addressed to that DID, and a mismatch shows
up only when Ingot's first S3 call is refused.

While central works on that, fund each Piri's owner wallet. Every Piri has its own, because the
provider registry allows one provider per address. A Piri registers itself in the registry on its
first start, and that transaction sends 5 tFIL from its wallet, so send each one at least 6 from a
Calibration faucet. The addresses are printed by `onboarding-request.sh`, and also readable
directly:

```sh
for piri in piri-0 piri-1 piri-2; do
  address="$(BAO_TOKEN="$(cat /etc/fil-one/bao-token)" docker exec \
    -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN filone-openbao \
    bao kv get -mount=filone -field=owner_wallet_address "$piri")"
  echo "$piri $address"
done
```

This is the only thing the node ever pays for. Proofs are paid by the central signing service from
`PAYER_ADDRESS`.

Central sends back ingot-proof.txt, hilt's delegation to this node's Ingot and the one piece of
onboarding only central can sign. Every `make onboard-appliance` command in the request writes the
same file name, and that is intended: the region has one Ingot, so central issues one delegation
and returns it byte for byte on every Piri's run. Store it once. When OpenBao already holds one,
after an app reset or when adding a Piri, `onboarding-request.sh` says so. If the Ingot DID is
unchanged, a central run that reports "returning the delegation issued earlier" leaves nothing to
store. If the Ingot DID changed, the same message means a stale delegation; see "When the Ingot
DID changes too" under [Re-onboarding after identity loss](#re-onboarding-after-identity-loss).

The file lands on your machine, and there is no SSH on the node to copy it across, so pass it to
`store-hilt-proof.sh` over stdin:

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

Each Piri's first start runs `piri init`, which calls the registrar for approval. A 403 there means
that Piri's DID is not on the delegator's allow list, which means its onboarding did not complete.

That first start also registers the provider and creates the proof set, and waits for both
transactions to land, which takes minutes. The Piris start one after another, each once the one
before it is healthy, because concurrent gas estimation makes the later `createDataSet` revert.
The first `provision-apps.sh` prints every Piri's log while it waits, prefixed with its service
name (`piri-0 |`), so a registration or a proof-set transaction that never confirms is visible as
it happens. Later runs skip init and print nothing extra.

`provision-apps.sh` finishes with acceptance checks: OpenBao restarts and unseals, each Piri answers
`/readyz`, Ingot answers `/health`, every hostname serves over HTTPS with an issued certificate, and
each Piri hostname serves the node status document.

It then installs the systemd units from the checkout, so the timers below exist whatever revision
the box was bootstrapped from.

### 7. The timers

```sh
systemctl enable --now filone-reconcile.timer
systemctl enable --now filone-seal-token-renew.timer
systemctl list-timers | grep filone
```

`filone-openbao-snapshot.timer` is not on that list on purpose. `provision-backups.sh` enables it
on a node that takes backups, once the stored key has written to the bucket, and a node without a
working key has nothing to upload with.

From here, changes reach the node by being merged. The node tracks whatever `FILONE_GIT_REF` in
`/etc/fil-one/node.conf` names, which bootstrap writes as `main`.

Finish with the node's smoke test:

```sh
scripts/ci/smoke-test.sh <node>          # `dev`, or `staging/eu-central-3`
```

## Day-to-day operations

Commands in this section run from the infra-nodes checkout: `/opt/fil-one/infra-nodes` on the
cloud nodes and `/root/fil-one/infra-nodes` on staging, the `FILONE_CHECKOUT` value in
`/etc/fil-one/node.conf`.

### Open a shell on a node.

The two nodes are reached differently.

#### dev

Dev has no SSH: no inbound port 22, no key pair, no bastion. The way in is AWS Systems Manager
Session Manager, which works because the SSM agent on the node dials out. You need credentials for
the filone-sandbox account, the Session Manager plugin for the AWS CLI (`brew install --cask
session-manager-plugin`), and an initialised `terraform/envs/dev`, because the script reads the
instance id from state rather than taking one as an argument. The node and its state bucket are in
us-east-2, so the CLI needs that region:

```sh
tofu -chdir=terraform/envs/dev init      # once
AWS_REGION=us-east-2 scripts/operator/ssm-session.sh dev
sudo -i
cd /opt/fil-one/infra-nodes
```

The session starts as `ssm-user`; the secrets tmpfs, the token files and the docker socket are
root's, hence `sudo -i`.


#### staging

Staging is a bare-metal host and takes SSH as root. Your public key has to be in root's
`authorized_keys` on the host, which someone who already has access adds:

```sh
ssh root@23.83.66.244
cd /root/fil-one/infra-nodes
```

The host owns the Lotus, Caddy and Alloy running there. FilOne leaves them alone.

**Deploy a new image.** Nothing to do. Piri and Ingot dispatch their new digest here when they
publish a `:main` image, `bump-deployed-image.yml` opens the pull request that rewrites
`nodes/dev/apps/versions.env`, and auto-merge lands it once `tofu`, `shell` and `compose` pass.
Within five minutes of the merge the node pulls, then restarts the Piris one at a time, each after
waiting for its own safe proving window and health-gated before the next goes down, and then Ingot.
A Piri taken out of `compose.yml` is stopped before any of that, also behind its own gate, and then
removed.

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
malformed digest or a pin somebody moved to another tag. It pins dev unless `--node` names another
node, as in `--node staging/eu-central-3`.

**Promote to staging.** Merge the open "Promote dev's images to staging" pull request.
`promote-staging.yml` keeps it on every push to `main`: it sets each of staging's pins to what dev
pins, lists what each service brings over staging's current pin, and closes itself once the two
match. It never enables auto-merge, and disables one enabled for an earlier head, since a new head
is a new set of images. Staging then deploys as dev does, on its next reconcile pass and after the
proving window.

To hold one service back, push to `bot/promote-staging` yourself: while its pull request is open,
the workflow neither rebuilds nor closes a branch whose head the bot did not both author and
commit, so an amended bot commit counts as a push. Or promote by hand in a branch of your own,
with `set-node-pin.sh --node staging/eu-central-3`.

A deploy that fails is retried on the next pass. Each project records the revision it was last
deployed from, so reconcile compares against that rather than against the previous HEAD; the failed
commit stays outstanding until a deploy of it succeeds.

**Check a node by hand.** The smoke test needs no credentials and checks the node the way the world
sees it:

```sh
scripts/ci/smoke-test.sh dev
curl -s https://piri-0.us-east-9.latest.dev.fil-forge.com/.well-known/filone-node-status.json | jq
```

The document carries a revision per stamp. `reconcile` is the commit the node has reached, advanced
on every pass; `apps` and `platform` move only when that project deploys. The smoke test waits on
`reconcile` and compares the running digests against the pins at `apps`, which is what proves a bump
took. The Piris it checks are the ones `compose.yml` defined at `apps`, so a merged Piri the node has
not deployed yet is not probed. `smoke.yml` runs the same test after every merge and hourly.

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

**Add the backup key to a node provisioned before it existed.** Ask central for a plain re-run of
`make mint-appliance-credentials` for the region. The node's unseal token is live, so central skips
it and mints only the backup key. Then, on the node:

```sh
scripts/host/provision-backups.sh
```

It asks for the backup-key wrapping token, stores the key and its target at `filone/backup-target`,
and checks that the key can write there. A second run reports the key it holds, changes nothing,
and checks it again.

**Check the backup key.** To confirm at any time that the stored key can still write to its
target:

```sh
scripts/host/check-backup-target.sh
```

It puts a small object at `<region>/provisioning-check/<UTC timestamp>` in the backup bucket. The
key can neither read nor delete it; the bucket's lifecycle removes it after 36 days, as it does
every backup. An `InvalidAccessKeyId` means central deleted the key, usually by reissuing it, and
the fix is `provision-backups.sh --replace` with the new wrapping token.

**Reissue the backup key.** When the key leaked, or `provision-backups.sh` could not exchange its
wrapping token, ask central to run the mint with `MINT_ARGS=--reissue-backup-key`. That deletes the
old key in IAM before minting the new one, so the node's uploads fail until it stores the new key:

```sh
scripts/host/provision-backups.sh --replace
```

The unseal token is left alone; the two credentials are reissued independently.

**OpenBao snapshots.** On a node that takes backups, `filone-openbao-snapshot.timer` uploads a raft
snapshot of the node's OpenBao once a day, to `<region>/openbao/<UTC timestamp>.snap` in the backup
bucket. Anything that writes to OpenBao (provisioning, a deploy that stores a new secret, a new
region key) leaves a marker at `state/openbao-snapshot-pending` under the node's
`FILONE_CONTROL_DIR`, and the end of that run, or the next reconcile pass, starts a snapshot
straight away. The marker is cleared only after an upload succeeds, and any run that fails sets it,
so a failed snapshot, the daily one included, is retried every five minutes. A run renames the
marker to `state/openbao-snapshot-claimed` while it works; one left behind by a killed run is
harmless, and the next run takes it over. Runs take turns through
`/run/fil-one/openbao-snapshot.lock`, so one started by hand waits for the timer's.

A snapshot leaves the node as OpenBao wrote it. OpenBao encrypts every value before it reaches
raft, and central's `appliance-unseal-<region>` transit key wraps the root key, so a snapshot
cannot be read without the unseal key at central; the root token and recovery key alone cannot
unseal it. Mount paths, policy names and secret names stay in plaintext. The bucket locks each
snapshot in compliance mode for central's `appliance_backups.retention_days` (35 days on staging)
and deletes it a day after that. Never raise `min_decryption_version` on the unseal key inside
that window, or the older snapshots stop restoring.

To take one now, as root:

```sh
scripts/host/snapshot-openbao.sh
```

Each run stamps `openbao_snapshot_last_success_timestamp`, described in
[observability.md](observability.md#the-openbao-snapshot-stamp).

[Restore the appliance's OpenBao from a snapshot](runbook/restore-openbao-from-snapshot.md) brings a
lost store back from one of these snapshots, checks a snapshot without downtime, and describes the
quarterly restore drill.

**Give a node a new host token.** The host token is the OpenBao token every deploy, reconcile pass
and snapshot runs as, under the `filone-host` policy. A node provisioned before snapshots existed
holds one under the older `filone-deploy` policy, which cannot take a snapshot, and its snapshot job
says so. Rotate the token the same way, or replace it after a restore from a snapshot older than
the token's 72-hour period:

```sh
scripts/host/provision-host-token.sh
```

It asks for the root token from 1Password, writes the policy, puts the new token in
`/etc/fil-one/bao-token` before revoking the old one, and deletes `filone-deploy`.

On a node that already holds its backup key and predates snapshots, run the two in this order:
`provision-host-token.sh`, then `provision-backups.sh`. The second checks the key, uploads the
first snapshot and enables the timer; run first, it stops at the snapshot that the old token
cannot take.

**Rotate the root token after a leak.**
[Rotate the root token of an appliance's OpenBao](runbook/rotate-openbao-root-token.md) mints a
replacement, revokes the leaked token and covers the snapshots that still hold it.

**Reissue the Piris' delegations to sprue after SPRUE_DID or their commands change.** Run
`keygen.sh` again; provisioning runs it too. It compares each delegation's stored audience and
commands against the current `SPRUE_DID` and the script's command list, and reissues when either
differs, so this is the same command as the first run. The proofs are read only by
`onboarding-request.sh`: sprue keeps the copy it was given at registration, so a provider already
registered there needs registering again before it holds the new delegation.

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
docker logs --tail 200 filone-piri-0
```

In Grafana Explore, select the Loki datasource and query `{appliance="dev-us-east-9"}` for
everything the node ships, or `{node="dev"}` for one box. Docker logs carry
`service_name="appliance-<stage>-<region>-<compose-service>"`, so Piri on dev is
`{service_name="appliance-dev-us-east-9-piri"}`, Piri on staging is
`{service_name="appliance-staging-eu-central-3-piri"}`, and Ingot ends in `-ingot`. The Piris
share one `service_name`; add `instance="dev/piri-1"` to read one of them.

Host metrics sit in the Prometheus datasource under the same `appliance`, `node` and `region` labels, with
`service_name="appliance-<stage>-<region>-host"` and `instance` set to the node name, so
`node_filesystem_avail_bytes{node="dev"}` is the dev appliance's free space. On dev the series
come from the Alloy container's node exporter; on staging they come from the host's own exporter
and cAdvisor, so container metrics such as `container_memory_working_set_bytes` exist for staging
only. Caddy's request metrics ship from both nodes under `service_name="appliance-<stage>-<region>-caddy"`
and `job="caddy"`; [observability.md](observability.md#caddy-requests) has the 5xx queries.

**Reset the apps on dev or staging.** This drops the `ingot` and Piri databases, empties the apps'
data directories and recreates the databases empty. It keeps the node's identity: OpenBao and its
unseal token, every key and wallet, and the hilt proof. The node is reset first, and the apps stay
stopped until central has been reset too:

```sh
scripts/host/reset-apps.sh
```

It shows what it will stop, drop and empty, and asks you to type `reset-<stage>`; `--yes` skips the
question. It refuses any other stage. Hold merges to `main` until central is reset, and watch for
dev's image bumps, which merge on their own: a reconcile pass that deploys the apps or the platform
starts them again. After that, the next `deploy-apps.sh` starts them, and each Piri creates a new
proof set and needs onboarding again. infra-central's
[app reset guide](https://github.com/fil-forge/infra-central/blob/main/docs/reset-apps.md) has the
full order, and the on-chain cost of leaving the old proof sets behind.

**Move Ingot's data directory on staging.** A one-off for the change that moved it from the ZFS pool
to `/var/lib/fil-one/ingot` on the root SSD. The spool holds bodies not yet uploaded to Piri and the
catalog log under `segments`, so copy them across before the new mount goes live. Before merging
that change, stop reconcile and Ingot, and copy. Stopping the timer leaves a pass already running,
which could start Ingot again mid-copy, so wait for it to finish rather than kill a deploy halfway:

```sh
sudo systemctl stop filone-reconcile.timer
while [ "$(systemctl show -P ActiveState filone-reconcile.service)" = activating ]; do sleep 10; done
sudo docker stop filone-ingot
sudo install -d -m 0755 /var/lib/fil-one/ingot
sudo rsync -aHAX --numeric-ids /mnt/data/fil-one/data/ingot/ /var/lib/fil-one/ingot/
```

Merge, then deploy and restart the timer:

```sh
sudo scripts/host/reconcile.sh
sudo systemctl start filone-reconcile.timer
```

Staging takes no uploads from the `docker stop` until reconcile recreates Ingot. If reconcile runs
before the copy, Ingot fails to start on the missing directory rather than starting empty. Once
`docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' filone-ingot` lists
`/var/lib/fil-one/ingot` and `scripts/ci/smoke-test.sh staging/eu-central-3` passes, remove the old
copy: `sudo rm -rf /mnt/data/fil-one/data/ingot`.

**Move Postgres to the Debian image.** A one-off per node, for the change that moves Postgres from
`postgres:16-alpine` to `postgres:16-bookworm`. The new image cannot open the old cluster safely
([the decision record](decisions/2026-11-postgres-on-debian.md) says why), so the cluster moves by a
dump and restore into `postgres-glibc`, beside `postgres` in the control directory. Once the change
reaches a node, `deploy-platform.sh` refuses to run there until the move is done. Each reconcile
pass then stops at that point without changing anything, and the apps deploy, image bumps
included, waits behind it. On staging, "Appliance has stopped reconciling" fires about 25 minutes
later (15 minutes stale, then 10 pending); dev has no such alert. So run the move as soon as the
merge has reached the checkout, inside `tmux` or `screen` so a dropped session does not cut it
short:

```sh
sudo scripts/host/migrate-postgres-to-debian.sh
```

It prints each database's size and asks you to type `migrate-<stage>`; `--yes` skips the question.
It pulls the new image, waits for the proving gate and stops Piri and Ingot. Then it dumps every
database into `postgres-migration` on the control volume, starts the new cluster with locale
`C.UTF-8`, runs `postgres-init`, restores each dump in one transaction, and compares every table's
exact row count. Last it runs `deploy-platform.sh` and starts the apps. They are down from the gate
to the end, which takes as long as reading every database twice and writing it once; a Piri whose
challenge window opens meanwhile misses that proof. The reconcile stamp waits on the script too, so
a move that takes longer than 25 minutes on staging fires the alert above while it runs.

If a step fails after the old cluster stopped, or the run is interrupted (Ctrl-C, `kill`, a
hangup), the script starts the old cluster again under its old image and the apps on it, and the
guard stays in place. After a hangup, what it printed is in `state/migrate-postgres.log` in the
control directory. Fix the cause and run it again; it moves the half-built `postgres-glibc` aside to
`postgres-glibc.failed-<time>`, which you remove once you no longer need it.

A run killed outright, by `kill -9` or a reboot, cannot undo itself. It leaves the old cluster
stopped and the half-built one running, and `deploy-apps.sh` refuses to start the apps on it.
Put the old cluster back, with the apps on it, and then run the move again:

```sh
sudo scripts/host/migrate-postgres-to-debian.sh --rollback
```

Afterwards `docker inspect -f '{{.Config.Image}}' filone-platform-postgres-1` shows
`postgres:16-bookworm`, and the smoke test passes. The old `postgres` directory is the way back
until you remove it: reverting the change starts the old image on it, with the data as it was when
the move began, so everything written since is lost. The deploy that does that also forgets the
migration, so merging the change again later waits for a fresh move rather than starting the stale
copy. Once the node has run normally for a few days, remove the old directory
(`sudo rm -rf /mnt/fil-one/control/postgres` on dev, `sudo rm -rf /mnt/data/fil-one/control/postgres`
on staging). After that there is no way back but a restore, and a revert is refused rather than
starting an empty cluster.

## Re-onboarding after identity loss

On a node that takes backups, first
[restore its OpenBao from a snapshot](runbook/restore-openbao-from-snapshot.md), which keeps every
identity and needs no re-onboarding. This section is for a node with no snapshot that restores.

Losing the control volume loses the node's keys, so the rebuilt node comes back with new Piri
DIDs and central still carries the old ones. Ingot is unaffected as long as its hostname holds: the
`did:web` is derived from the region label and the content domain, both of which central also holds,
so a rebuilt node publishes a new key at the same DID and hilt's delegation to it stays valid.
Everything below is about Piri. A node whose Ingot hostname *does* change is a different case, at
the end of this section.

**1. Rebuild.** Attach a fresh control volume (or replace the instance and let cloud-init mount
one), then run `provision-platform.sh`. It initialises an empty OpenBao and generates new
identities. The transit key at central is per-node, not per-identity, so it stays. The unseal token
lives on the root volume and survives unless the instance was replaced too; if it was, ask central
for a new wrapping token. The backup key lived in the old OpenBao and is gone with it, so on a node
that takes backups ask central to run the mint with `MINT_ARGS=--reissue-backup-key` too: a plain
run would see the region's old key in IAM and skip it.

**2. Remove the old identities at central.** Ask whoever runs infra-central to drop the old Piri
DIDs from the delegator's allow list and to deregister or zero-weight the old providers at sprue.
hilt's provider row is keyed by the Ingot DID, which the rebuild does not change, so it stays as it
is.

**3. Onboard the new Piri DIDs.** [Step 6](#6-onboarding-then-the-apps) again, then
`provision-apps.sh` and the timers. hilt's delegation to Ingot is unchanged and central still holds
it in SSM, so ask for the same `ingot-proof.txt` back rather than a reissue, and store it with
`store-hilt-proof.sh`: the rebuilt OpenBao has no copy of it.

The Piri volumes and the data volume still hold the old identities' blobs and spool. Dev data is
disposable; wipe it and start clean rather than carry data the new identity cannot serve.

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
it will admit a region at all. It does not touch sprue's registration for the old Piri DIDs either,
which is the same tidying step 2 above describes.

## When something is wrong

**`provision-platform.sh` cannot exchange the wrapping token.** A wrapping token can be spent once,
so a token central refuses inside its 24-hour window is one somebody else has already spent. Treat
it as a compromise: ask central to re-mint with `MINT_ARGS=--reissue-unseal-token`, which revokes
the token that was taken, and work out who could read the channel it was delivered on.

**`provision-backups.sh` cannot exchange the wrapping token.** The same as for the unseal token:
somebody else spent it. Ask central to re-mint with `MINT_ARGS=--reissue-backup-key`, which deletes
the key that was taken, store the new one with `provision-backups.sh --replace`, and work out who
could read the channel.

**The OpenBao snapshot is stale.** The last upload to the backup bucket is more than a day old.
An age of centuries means the node reports no snapshot stamp at all: it has never uploaded one, so
run `provision-host-token.sh` if it predates snapshots and then `provision-backups.sh`, or the code
that writes the stamp is broken. Otherwise the snapshot unit's journal has the failed run's reason:
`{service_name="appliance-staging-eu-central-3-host", unit="filone-openbao-snapshot.service"}` in
Loki, or `journalctl -u filone-openbao-snapshot.service` on the host. A refused snapshot
means the host token still holds `filone-deploy`: run `provision-host-token.sh`. An
`InvalidAccessKeyId` means central deleted the backup key: store the new one with
`provision-backups.sh --replace`. Any other S3 error, or none at all, is easier to read from
`check-backup-target.sh`, which tests the key and the bucket on their own. A timer that stopped
firing shows in `systemctl list-timers filone-openbao-snapshot.timer`.

**OpenBao is sealed.** `docker logs filone-openbao` names which half failed: the token was refused
(revoked, expired, or the request came from an address the token is not bound to) or the transit key
does not exist. A node whose Elastic IP changed has a token bound to the old one and needs a new
token. [Recover from an expired appliance unseal token](runbook/recover-expired-unseal-token.md)
replaces it. A store restored from a snapshot that stays sealed is missing one of the things
[a restore needs](runbook/restore-openbao-from-snapshot.md#what-a-restore-needs).

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

**A Piri crash-loops with a 403 from the registrar.** Its DID is not on the delegator's allow list.

**A Piri crash-loops on `wallet balance is too low`.** Its owner wallet holds less than the 5 tFIL
provider registration sends to the registry. Fund it with at least 6, as [step
6](#6-onboarding-then-the-apps) describes, then re-run `provision-apps.sh`. Exactly 5 is not enough,
because the 5 is the transaction's value and the gas comes out of the same wallet.

**A Piri crash-loops on the chain endpoint.** A 403 with JSON-RPC error -32156 ("Access denied")
from Chain.Love means the chain.love token in OpenBao is wrong, expired, disabled, or not allowed
from this host's IP; rotate it there and re-run `deploy-apps.sh`. Piri sends the token
itself, from `PIRI_PDP_LOTUS_AUTH_TOKEN`, so check that the variable actually reached the container:
`docker inspect filone-piri-0` shows its environment.

A Piri that stays up after the provider starts rejecting its token keeps the old token until it is
recreated. The proving gate asks that Piri whether a restart is safe, the Piri cannot reach the
chain to answer, and the deploy waits out the gate's timeout before it aborts. Such a Piri cannot
submit a proof either, so stopping it first costs nothing: rotate the token, run
`docker stop filone-piri-<n>` for each Piri the gate reports as "cannot determine", then re-run
`deploy-apps.sh`.

### Piri's proving alerts

Piri's proving rules in infra-central's `terraform/envs/grafana/alerts.tf` link here. Each entry
below starts with how soon to act, then gives the steps in order. The severity definitions are in
infra-central's `docs/observability.md`.

#### Before you start

Dev and staging each run three Piris, `piri-0` to `piri-2`. Most alerts say which one:

- The chain-head, proving-failing, proving-period, deletion-drain, Prove-task and AddRoots alerts
  carry the Piri's `instance` label, for example `staging/eu-central-3/piri-1`. Its last digit is the Piri's
  number. The proving-failing, proving-period and deletion-drain alerts also name the `proof_set`.

- The unrecoverable alert carries the Piri's `instance` too, but not the proof set. Step 1 of
  [Piri proof set is unrecoverable](#piri-proof-set-is-unrecoverable) finds it in the logs.

1. On the host, run `bash` first if the login shell is Fish (it is on staging), so the commands
   paste as written. Set the Piri's number, for example `n=1` for `staging/eu-central-3/piri-1`.
   Its container is `filone-piri-$n`, its database `piri_$n`. The commands below fail if `n` is
   unset, rather than reach the wrong Piri.
2. Open a shell in it, in its data directory:

   ```sh
   docker exec -it -w /data/piri "filone-piri-${n:?}" sh
   ```

   The `piri` commands below run there, because they read `piri-config.toml` from the current
   directory. Anywhere else they need `--config /data/piri/piri-config.toml`, or they stop on a
   config error before reaching the node. Keep a second terminal on the host, in `bash` as in step
   1 and with the same `n` set, for the steps that say "on the host". If `docker exec` says the
   container is not running or is restarting, restart it as in step 4's **Anything else** bullet,
   then come back to this step.
3. The commands each entry uses:

   | To see | Run |
   |---|---|
   | Whether the node answers, and whether it's safe to restart | `piri status` |
   | The proof set's state and the chain's current epoch | `piri client pdp proofset state` |
   | Every proof set this Piri has | `piri client pdp proofset list` |

   `piri client pdp proofset state` shows the proof set named in the config; add `--proof-set <id>`
   for another one. `piri status` makes the same call, so it fails with the same errors.
4. If `piri client pdp proofset state` fails (or `piri status`, which makes the same call):
   - **`failed to get chain head`:** the chain endpoint. Run only the key check in step 2 of
     [Piri's chain head is stale](#piris-chain-head-is-stale) and fix what it finds, ignoring that
     entry's "go to" steps. Then restart Piri on the host, and come back to the entry you started
     from.
   - **`no proof set found`:** the database has no proof set with that ID. Check the ID against
     `piri client pdp proofset list`. If the one in `piri-config.toml` (`proof_set`) isn't listed,
     its data set has been deleted: record that on the incident, as for [Piri proof set is
     unrecoverable](#piri-proof-set-is-unrecoverable). Otherwise, use a listed ID and come back to
     the entry you started from.
   - **Anything else:** restart Piri on the host, `docker restart "filone-piri-${n:?}"`. It can show
     `health: starting` in `docker ps` for about eight minutes, or longer if its probes time out,
     before Docker marks it `unhealthy`.
     - **It becomes healthy and the error is gone:** come back to where you started from.
     - **The restart fails, or it ends `unhealthy` or keeps restarting:** on the host, check the
       files it mounts from the tmpfs:

       ```sh
       for f in "piri-${n:?}.pem" "piri-${n:?}-owner-wallet.hex" piri-base-config.toml; do
         test -f "/run/fil-one/secrets/$f" || echo "missing or a directory: $f"
       done
       ```

       If it prints `missing or a directory`, the node has rebooted: follow [The node
       rebooted](#the-node-rebooted). If it prints an error about `n` (`parameter null or not
       set`), set `n` as in step 1 and start this bullet again. If it prints nothing, record the
       error `docker restart` printed and `docker logs "filone-piri-${n:?}"` on the incident.
     - **It becomes healthy but the error comes back:** record the error in full on the incident.
5. The task logs are read on the host, not in the container. Prove tasks:

   ```sh
   docker logs "filone-piri-${n:?}" 2>&1 | grep -e PDPv0_Prove -e 'No such container'
   ```

   For scheduling, use `PDPv0_ProvPeriod` in place of `PDPv0_Prove`. Keep `${n:?}` and the second
   pattern: without them, an unset or wrong `n` prints nothing, which looks like a task that never
   ran.

Staging may still hold a database named `piri`, from when it ran one Piri. Nothing reads it.

#### Free stranded batches

Several entries end here. When Piri cannot add pieces on chain, each batch gets about 3.5 hours of
retries if the chain endpoint is unreachable, or 6.9 if it answers but is stale. After that Piri
gives up on the batch for good ([FIL-1508](https://linear.app/filecoin-foundation/issue/FIL-1508)).
Run this only after the cause is fixed, on the host:

1. Count the stranded batches:

   ```sh
   docker exec filone-platform-postgres-1 psql -U admin -d "piri_${n:?}" -c "
     SELECT count(DISTINCT s.add_task_id) AS batches, count(*) AS roots
     FROM curio.pdp_root_submissions s
     WHERE s.add_task_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM curio.harmony_task h WHERE h.id = s.add_task_id)"
   ```

2. If `batches` is 0, stop: nothing is stranded.
3. Otherwise free them. The next AddRoots run picks them up:

   ```sh
   docker exec filone-platform-postgres-1 psql -U admin -d "piri_${n:?}" -c "
     UPDATE curio.pdp_root_submissions s SET add_task_id = NULL
     WHERE s.add_task_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM curio.harmony_task h WHERE h.id = s.add_task_id)"
   ```

4. Run step 1 again. It should now show 0.

#### Piri's chain head is stale

**Act within about three hours.** Uploads and reads keep working, but Piri cannot add pieces on
chain, and after a few hours it gives up on them (see [Free stranded
batches](#free-stranded-batches)).

Dev and staging read the chain from Chain.Love (`LOTUS_RPC_URL` in `node.env`), not from a Lotus of
their own.

1. In the Piri's shell, run `piri client pdp proofset state`.
   - **It fails with `failed to get chain head`:** Piri cannot reach Chain.Love. Go to step 2.
   - **It fails with any other error:** read it as in [Before you start](#before-you-start),
     step 4.
   - **It prints a Current Epoch:** that is Chain.Love's head right now. Go to step 3.
2. On the host, check the Chain.Love token with the key check under [The eu-central-3 staging
   appliance on Servers.com](#the-eu-central-3-staging-appliance-on-serverscom); it works on dev
   too.
   - **403:** fix it as in "A Piri crash-loops on the chain endpoint" above, then go to step 5.
   - **101 Switching Protocols:** the token is fine. Go to step 4.
   - **No `HTTP/1.1` line at all, only curl's timeout, or another status:** the host can't reach
     Chain.Love. Check the host's network and Chain.Love's status page, then come back to step 1
     once it answers.

   A working key prints the `101` line and then a timeout, because the WebSocket stays open; that
   timeout is expected.
3. Compare Current Epoch with Calibration's current height on a block explorer. A Current Epoch of
   0 doesn't mean Chain.Love is behind: it means this proof set is not initialised, or Curio has
   given up on it, so the command shows no head. Run it again with `--proof-set <id>` for an
   initialised proof set from `piri client pdp proofset list`. If this Piri has none, go to step 4.
   - **Behind:** Chain.Love is lagging. Nothing to fix on the node; wait for it to catch up, then go
     to step 5.
   - **Current:** go to step 4.
4. Chain.Love is fine, so Piri's own subscription is stuck. Piri resubscribes after five minutes
   without a tipset, so if the alert has fired, restart it, on the host: `docker restart
   "filone-piri-${n:?}"`. The proving-window gate doesn't apply, since Piri isn't proving without
   a head.
5. Wait for the alert to clear, then [free stranded batches](#free-stranded-batches).

#### Piri is reporting but has no chain head

**Act within about three hours**, as for a stale head. Piri has not seen a single tipset since it
started, usually because the chain endpoint was unreachable then.

1. In the Piri's shell, run `piri client pdp proofset state`.
   - **It fails with `failed to get chain head`:** run only the key check in step 2 of [Piri's
     chain head is stale](#piris-chain-head-is-stale), and fix what it finds, ignoring that
     entry's "go to" steps. Then come back to step 2 here.
   - **It fails with any other error:** read it as in [Before you start](#before-you-start),
     step 4.
   - **It prints a Current Epoch:** the endpoint answers now. Go to step 2.
2. Restart Piri, on the host: `docker restart "filone-piri-${n:?}"`.
3. Wait for the alert to clear, then [free stranded batches](#free-stranded-batches).

#### Piri proving is failing

**Act now.** The alert fires in one of two cases:

- **No proof landed.** PDPVerifier has accepted no proof for this proof set for longer than a
  proving period plus its challenge window. The contract has recorded a fault, and each further
  period records another.
- **Piri cannot read the last proof.** Piri cannot read the proof set's last proven epoch from
  PDPVerifier, so a fault is possible but not confirmed. Piri logs `reading proof set's last proven
  epoch` with the error on the same line. The usual cause is the chain endpoint.

1. Check whether "Piri's chain head is stale" or "Piri is reporting but has no chain head" is also
   firing for this Piri. If either is, follow that entry first: without a chain, Piri can neither
   send a proof nor read the epoch.
2. On the host, read the `PDPv0_Prove` logs, then `PDPv0_ProvPeriod`. Look for a contract revert,
   `no subpiece found`, a send that failed for gas, or no run at all.
3. In the Piri's shell, run `piri client pdp proofset state` for the proof set the alert names. If
   it fails, read the error as in [Before you start](#before-you-start), step 4.
4. Act on what the logs showed:
   - **The data set's payment has ended or been terminated, or the data set is no longer live:**
     Curio stops proving it for good, and the next alert is [Piri proof set is
     unrecoverable](#piri-proof-set-is-unrecoverable). Follow that.
   - **`Proving period scheduling blocked by pending piece deletions; draining first` in the
     `PDPv0_ProvPeriod` logs, or "Piri's deletion drain is stuck" firing for this proof set:**
     follow [Piri's deletion drain is stuck](#piris-deletion-drain-is-stuck). PDPVerifier won't
     schedule the next proving period while piece removals are queued.
   - **Any other contract revert:** Curio retries, but the node can't fix a revert. Post the revert
     reason, the proof set's ID and its state in `#filone-eng` on Slack, now, and record them on
     the incident. The data set's payments are set up from central, which pays from
     `PAYER_ADDRESS`.
   - **A send that failed for gas, or no Prove run at all:** follow [Piri's Prove task has not run
     in 1.5 proving periods](#piris-prove-task-has-not-run-in-15-proving-periods). The owner
     wallet pays the gas, and that entry checks it.
   - **`no subpiece found`:** Piri is proving pieces it has no record of. Post the log lines and the
     proof set's ID in `#filone-eng`, and record them on the incident.

The alert clears on its own once a proof lands.

#### Piri's proving period has not advanced

**Act within a day.** A challenge window closed and Piri didn't schedule the next one. Each day
costs that day's proving period, and nothing more: once scheduling runs again, Curio carries on.

1. Check whether "Piri's chain head is stale" or "Piri is reporting but has no chain head" is also
   firing. If either is, follow that entry first; a head that isn't moving is the usual cause. If
   "Piri's deletion drain is stuck" is firing for this proof set, follow [that
   entry](#piris-deletion-drain-is-stuck) instead: PDPVerifier won't schedule the next proving
   period while piece removals are queued.
2. In the Piri's shell, run `piri status`. If it fails, read the error as in [Before you
   start](#before-you-start), step 4. If it answers, go on: the task engine can still be stalled
   behind a node that answers, which the logs show.
3. Check the owner wallet. An empty one stops scheduling and AddRoots without paging. Each Piri has
   its own; print its address on the host:

   ```sh
   BAO_TOKEN="$(cat /etc/fil-one/bao-token)" docker exec -e BAO_ADDR=http://127.0.0.1:8200 \
     -e BAO_TOKEN filone-openbao bao kv get -mount=filone -field=owner_wallet_address "piri-${n:?}"
   ```

   Look the address up on a Calibration block explorer. If it holds little or no tFIL, fund it as
   [step 6](#6-onboarding-then-the-apps) describes.
4. On the host, read the `PDPv0_ProvPeriod` logs for whether scheduling ran, and why not. If they
   say `Proving period scheduling blocked by pending piece deletions; draining first`, follow
   [Piri's deletion drain is stuck](#piris-deletion-drain-is-stuck): its steps apply before its
   own alert fires, which is a proving period later than this one.
5. Once scheduling runs again, if the logs showed AddRoots failing too, [free stranded
   batches](#free-stranded-batches).

#### Piri's deletion drain is stuck

**Act within a day.** Piece removals have been queued on a proof set for longer than its proving
period. PDPVerifier won't schedule the next proving period while removals are queued, so Curio
drains them first, with a `processPieceDeletions` transaction from the Piri's owner wallet. Until
the drain finishes, the proof set's proving periods stop advancing, and each day costs that day's
period. Once it finishes, Curio carries on. By the time this alert fires, "Piri proving is failing"
usually is too; if it is, act now.

1. Check whether "Piri's chain head is stale" or "Piri is reporting but has no chain head" is also
   firing. If either is, follow that entry first: Curio sends the drain when the challenge window
   closes, which it learns from the chain head.
2. Check the owner wallet as in step 3 of [Piri's proving period has not
   advanced](#piris-proving-period-has-not-advanced). It pays for every drain transaction.
3. On the host, read the Piri's logs for the drain. A `PDPv0_ProcDel` run that failed logs
   `Removal queue draining failed` with the data set's ID and the error. A drain transaction that
   was sent but failed on chain logs `PDP removal drain transaction failed` with its `txHash`. A
   successful one logs `submitted PDP processPieceDeletions`, then `PDP removal drain confirmed`.
4. Act on what the logs showed:
   - **`processPieceDeletions gas estimate failed at batch size 1`, `PDP removal drain transaction
     failed`, or any other contract revert:** the node can't fix it. Post the error, the
     transaction hash if there is one, and the proof set's ID in `#filone-eng` on Slack, and
     record them on the incident.
   - **`submitted PDP processPieceDeletions` with no `confirmed` or `failed` line for its `txHash`
     an hour later:** the transaction is stuck. Escalate it as above, with the `txHash`.
   - **Any other error, such as the wallet running out of funds:** check the wallet as step 2 says,
     and fund it if it's low. Curio retries the drain on its own.
   - **No `PDPv0_ProcDel` run at all:** run `piri status` as in step 2 of [Piri's proving period
     has not advanced](#piris-proving-period-has-not-advanced). The task engine may be stalled.

The alert clears once the drain finishes and Piri stops reporting the removals as queued.

#### Piri's Prove task has not run in 1.5 proving periods

**Act within a day.** No proof has gone out for one and a half proving periods: one period's
payment is already lost, and each further day loses another. Proving resumes once the cause is
fixed. Causes that can lose more page on their own, as "Piri proving is failing" and "Piri's chain
head is stale"; follow those first if they're firing.

1. Run steps 2 and 3 of [Piri's proving period has not
   advanced](#piris-proving-period-has-not-advanced):
   `piri status`, then the owner wallet.
2. In the Piri's shell, run `piri client pdp proofset state` for each proof set.
3. On the host, read the `PDPv0_Prove` logs for why no run finished.
4. Once it's fixed, if the logs showed AddRoots failing too, [free stranded
   batches](#free-stranded-batches).

#### Piri proof set is unrecoverable

**Act within a day.** Curio has given up on a proof set and won't prove it again. The loss has
already happened, so there is nothing to race.

1. On the host, find why in the `PDPv0_Prove` and `PDPv0_ProvPeriod` logs: the last rejection
   before Curio gave up.
2. Record the proof set's ID and the reason on the incident. What to do with the data set is
   decided outside this runbook.

#### Piri has untracked add pieces

**Act within a day.** A piece addition for the proof set succeeded on chain more than 10 minutes
ago, and Curio has not recorded its pieces from the receipt. Curio retries on every chain head and
reports no failure. A new proof set is not scheduled for proving until its first addition is
recorded, and the added pieces are not proven. The contract records no faults while this holds.

1. On the host, read the Piri's logs for the addition:

   ```sh
   docker logs "filone-piri-${n:?}" 2>&1 | grep -e 'pieces from receipt' -e 'No such container'
   ```

2. If the error names an event that wasn't found in the receipt, PDPVerifier now emits an event
   Piri's Curio can't parse, usually after a contract upgrade. The node can't fix this. Post the
   error, the proof set's ID and the transaction hash in `#filone-eng` on Slack, and record them on
   the incident. A Piri release with a newer Curio records the additions once it is deployed.
3. Otherwise, record the error on the incident and post it in `#filone-eng`.

#### Piri is not adding aggregates on chain

**Act within a day.** Blobs folded into an aggregate more than 10 minutes ago are still waiting for
AddRoots to add the aggregate on chain. They stay readable but are not proven until they land.
AddRoots sends a batch within 30 seconds and waits about 4 minutes for it to confirm, so a healthy
Piri's oldest waiting blob is under 5 minutes old. After about 3.5 hours of failing retries Piri
gives up on a batch, and its blobs wait until it is freed.

1. If "Piri's chain head is stale" or "Piri is reporting but has no chain head" is also firing for
   this Piri, follow that entry first: AddRoots needs the chain endpoint. Come back to step 2 once
   it clears.
2. On the host, read the AddRoots logs. Read all of them: a batch Piri gave up on hours ago leaves
   nothing in the recent ones.

   ```sh
   docker logs "filone-piri-${n:?}" 2>&1 | grep -e PDPAddRoots -e 'AddRoots transaction' -e 'No such container'
   ```

   - **`AddRoots transaction confirmed successfully` lines keep appearing up to now:** batches are
     landing, but aggregates are folded faster than AddRoots sends them. Go to step 4.
   - **Anything else** (errors, or no AddRoots lines at all): go to step 3. If there are no lines at
     all, run `piri status` in the Piri's shell first; if it fails, read the error as in [Before you
     start](#before-you-start), step 4.
3. Check the owner wallet as in step 3 of [Piri's proving period has not
   advanced](#piris-proving-period-has-not-advanced): an empty one fails every AddRoots
   transaction.
   - **It holds little or no FIL:** fund it as that step describes, then go to step 5.
   - **It holds FIL:** record the last AddRoots error from step 2 on the incident and post it in
     `#filone-eng` on Slack. Go to step 5 once the error is understood and fixed, or straight away
     if the logs showed no error, since the batch may have failed on something that has passed.
4. AddRoots sends at most 10 aggregates per transaction, three transactions at a time, so a Piri
   folding more than about 30 aggregates every 5 minutes falls behind. The node can't change this.
   Post the alert and the logs' rate of confirmed transactions in `#filone-eng`; the fix is a larger
   `pdp.aggregation.manager.batch_size` in Piri's base config, or larger aggregates.
5. [Free stranded batches](#free-stranded-batches). Then, after 5 minutes, read the logs as in step
   2 again: `AddRoots transaction confirmed successfully` should appear. If AddRoots fails again,
   go back to step 3. The alert clears when the oldest waiting blob is under 10 minutes old again.

### The node rebooted

The Piris and Ingot come back down, and stay down until an apps deploy runs. Their
keys and rendered configs live on a tmpfs that a reboot empties, and Docker restarts the containers
before anything has rendered them again, so each restart fails on a missing bind-mount source.
Reconcile does not notice: it deploys a project only when a commit has touched it since the last
deploy, and the deployed revision is on the control volume, so a reboot leaves nothing to do. The
hourly smoke test reports the node not answering within the hour. Render and start the apps by hand:

```sh
scripts/host/deploy-apps.sh
```

The next commit that touches the apps project, an image bump included, would do the same on its own.
Platform comes back by itself: OpenBao carries its seal token in its environment and unseals against
central without any file from the tmpfs.

A Piri that instead logs `read /keys/piri.pem: is a directory` is on a node whose compose file lets
Docker create a missing bind-mount source. Docker puts an empty directory where the file belongs,
every later render lands inside it, and every pass fails its health wait without stamping. Stop the
timer, clear the directories, deploy by hand, and start the timer again:

```sh
systemctl stop filone-reconcile.timer
docker stop filone-piri-0 filone-piri-1 filone-piri-2 filone-ingot
find /run/fil-one/secrets -mindepth 1 -type d -exec rm -rf {} +
scripts/host/deploy-apps.sh
systemctl start filone-reconcile.timer
```

**The proving gate never lets a deploy through.** `pdp-gate.sh` waits 45 minutes by default. If a
Piri reports "not safe" for that whole time, the deploy aborts rather than risk a proof; re-run it
after the challenge window. A Piri that owes proofs and will not report its state at all is treated
the same way, most often because the chain RPC is unreachable. A platform deploy waits until every
Piri reports safe in the same poll, because restarting Postgres stops all of them at once; three
Piris whose challenge windows rarely line up can take longer than one.

**The gate says `piri-config.toml` is missing.** The container is running but the file is not there
yet, which is where a node sits while `piri init` is still working and where it stays if init died.
`docker logs filone-piri-<n>` says which of the two it is. The gate lets the deploy through only
when init's stamp is missing too: `piri-init.stamp`, or `piri-base-config.applied.toml` on a node
that has not re-run init since the stamp replaced it. The entrypoint writes the stamp once init
returns, so a node that has never got that far holds no proof set. A missing config next to a
present stamp aborts the deploy: init has completed here before, so Piri may still owe a proof.
Restore the config, or `docker stop filone-piri-<n>` if that Piri is being decommissioned.

**Piri logs `WARNING: init failed; serving the existing config version N`.** Piri's entrypoint
re-runs `piri init` whenever one of init's inputs changes: the base config, a `node.env` value init
takes as a flag (public URL, chain endpoint, registrar, PLC directory, operator email), the Postgres
URL, so a rotation of Piri's database password too, or a Piri image that writes a different config
version, which a rollback to an older image does as well as an upgrade. It happens on the next
recreate, which `deploy-apps.sh` does behind the proving gate, so an image bump or such a `node.env`
edit costs one init run, not just a restart. The chain RPC token is not an input of init's: `serve`
reads it from the environment, so a rotation needs only a recreate. A re-run that fails, or does not
finish within 5 minutes (`PIRI_INIT_TIMEOUT` in `node.env`, in seconds; a value that is not a whole
number without leading zeros falls back to 300 with a warning; keep it well under the 420 seconds
`deploy-apps.sh` waits for a recreated Piri to turn healthy, at most 360, since that wait also
covers `serve` starting), ends in this warning when it is safe
to carry on: the image writes a different config version, it is the first start since the stamp
replaced the snapshot and the old snapshot still matches the base config, or init timed out. Piri
then serves the config already on disk, which holds its proof set; `N` is that config's version. A
preceding `did not finish within` line means init was killed with SIGKILL (exit 137): usually by the
timeout, but the kernel's OOM killer exits the same way, and `dmesg` on the host tells the two
apart. The first-start case can hide a `node.env` change that lands in the same deploy: the
config served lacks it until init next succeeds. Any other failure of a re-run still exits, and
Docker restarts the container into the same init. The lines before the warning in the Piri's `docker
logs` carry init's own error, most often the registrar or chain RPC being unreachable. A kill
partway through init is harmless: the wallet import is idempotent and the key files are mounted
read-only, so the next run recovers.

**Piri logs `WARNING: skipping init: it already failed for this Piri and these inputs`.** After the
warning above, the entrypoint writes `piri-init.failed` beside `piri-config.toml`, holding the Piri
binary's hash, the config version it tried to write and the hash of init's inputs. While all three
still match, every later start, whether a gated recreate, a crash, a reboot or a Docker restart,
skips init and serves the existing config straight away, rather than holding off proving for another
failed run each time. Until init succeeds the node serves the older config, which is safe but misses
whatever the re-run was for. A new Piri image or a change to any of init's inputs retries on its
own, a start that needs no init deletes the file, and so does a successful init. To retry with
nothing changed, fix the cause, then wait for the gate, delete the file and restart Piri, in that
order and straight away, so the restart lands in the window the gate found. Run it from the
checkout, holding the deploy lock so a reconcile can neither reset the checkout under the gate nor
recreate Piri around the restart:

```sh
cd /opt/fil-one/infra-nodes
sudo flock /run/fil-one/deploy.lock sh -c 'scripts/host/pdp-gate.sh piri-0 \
  && rm /mnt/fil-one/piri-0/piri-init.failed \
  && docker restart filone-piri-0'
```

Those are dev's checkout and `piri-0`'s service, data directory and container; the other Piris are
`piri-1` and `piri-2`. Staging runs the same three Piris, with the same service and container names;
only its checkout (`/root/fil-one/infra-nodes`) and data directories
(`/mnt/data/fil-one/data/piri-<n>/`) differ.
Deleting the file without the restart retries on the next start of any kind, gated or not;
`deploy-apps.sh` does not recreate Piri when nothing has changed.

**Piri logs `ERROR: init wrote a config naming proof set N in place of M`.** A re-run of init
came back with a config naming a different proof set from the one the node was proving. `piri init`
reuses the one proof set listed in Piri's Postgres (`pdp_data_sets`), and creates a new one on chain
when that table lists none. So the database init used either had lost the node's proof set or was a
different database: a reset, a restore from an older backup, or a `node.env` change to the Postgres
URL. A different database that already lists a proof set is adopted rather than created, and that
proof set need not be this node's. Either way, by the time the entrypoint sees the config, init has
already done it. The entrypoint puts the previous config back, serves it, and writes
`piri-init.failed` as for the warnings above, so later starts skip init until the image or init's
inputs change.

What that leaves depends on the cause. `serve` reads the database URL from the config, not from
`node.env`, so after a URL change the restored config points Piri back at the database it had, and
the node keeps proving `M`; put the URL in `node.env` back, or decide to move. After a reset or an
older restore of the same database, the restored config names `M` but the database no longer
holds it: Piri cannot add roots to `M` or prove it, and it will fault. Restoring that database is
then urgent. In both cases, make sure the database `node.env` points at holds proof set `M` before
retrying; a retry against one that lists only `N` comes back with `N` again. What to do with `N` on
chain is a decision for whoever owns the wallet, not something to do from the node.

**Piri logs `WARNING: restoring the config from before an init that did not finish`.** The
container stopped during a re-run of init, after the entrypoint copied the config to
`piri-config.toml.before-init` and before it checked what init wrote. The copy is put back before
anything else reads the config, so this start decides from the config the node was serving, and a
proof set that run created or adopted is caught by the check above if init runs again. If init does
not run again, for instance because the change to its inputs was reverted in the meantime, check the
wallet's proof sets on chain for one the interrupted run created.

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
