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
| `provision-platform.sh` also asks for | the chain.love and Grafana Cloud tokens | neither: Lotus RPC is local and unauthenticated, Alloy is the host's |

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
network, node config, systemd units, the Caddy import and the three FilOne UFW
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
ufw allow from 172.18.0.0/16 to any port 1234 proto tcp \
  comment 'FilOne Docker to host Lotus RPC'
ufw status numbered
```

The two rules let Piri call its public Ingot URL and the host-owned Lotus RPC.
Do not allow TCP 1234 from the public internet. Remove old FilOne rules tied to
`docker0` or another Docker bridge after confirming these source-subnet rules.

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

Give the reconcile journal source
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
  // Piri reports its DID as service.instance.id; name the node, as every
  // other appliance series does.
  rule {
    target_label = "instance"
    replacement  = "staging/eu-central-3"
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

**8. Check Piri can reach it**, from inside the Piri container, through the host gateway and UFW:

```sh
docker exec filone-piri wget -q -O - --header 'Content-Type: application/json' \
  --post-data '{}' http://host.docker.internal:4318/v1/metrics
```

It prints `{"partialSuccess":{}}`: an empty export, accepted. A timeout means the UFW rule is
missing; `connection refused` means Alloy is not listening on 4318.

Each service's series then arrive in Grafana under `job="forge/<service>"` (Piri's as
`job="forge/piri"`), and each service's traces under `service.name="<service>"` with
`service.namespace="forge"`; `docs/observability.md` has the queries. Ingot sends traces only, so
far.

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
make mint-appliance-token STAGE=<stage> REGION=<region> NODE_IP=<the address>
```

What comes back to you is a **wrapping token**, not the unseal token itself. The credential stays
inside the central OpenBao until the node claims it in step 5. The wrapping token can be spent once
and expires in 24 hours, so chat is an acceptable channel for it; a view-once 1Password link is
better.

### 5. The platform

Open a shell on the node as root, in its checkout; step 3 gives both for each node. The rest of
the bring-up runs in this shell.

```sh
scripts/host/provision-platform.sh
```

It asks for the wrapping token, exchanges it at central for the unseal token, initialises OpenBao,
and prints **one recovery key and one root token**.
Both are printed once and stored nowhere on the node. Put both in 1Password before continuing: with
neither, the only way back into this OpenBao is to rebuild the node and re-onboard it.

It then asks for the root token back twice, to create the deploy token and the KV mount and then the
region key Ingot encrypts objects under; installs the identity tooling (ucantool and cast, pinned in
the node's `node.env`); generates the node's keys; asks for whichever operator-supplied tokens
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
the box was bootstrapped from.

### 7. The timers

```sh
systemctl enable --now filone-reconcile.timer
systemctl enable --now filone-seal-token-renew.timer
systemctl list-timers | grep filone
```

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
malformed digest or a pin somebody moved to another tag. It pins dev unless `--node` names another
node, as in `--node staging/eu-central-3`.

**Promote to staging.** Merge the open "Promote dev's images to staging" pull request.
`promote-staging.yml` keeps it on every push to `main`: it sets each of staging's pins to what dev
pins, lists what each service brings over staging's current pin, and closes itself once the two
match. It never enables auto-merge, and disables one enabled for an earlier head, since a new head
is a new set of images. Staging then deploys as dev does, on its next reconcile pass and after the
proving window.

To hold one service back, push to `bot/promote-staging` yourself: while its pull request is open,
the workflow leaves a branch it did not last push alone. Or promote by hand in a branch of your own,
with `set-node-pin.sh --node staging/eu-central-3`.

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

**3. Onboard the new Piri DID.** [Step 6](#6-onboarding-then-the-apps) again, then
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
6](#6-onboarding-then-the-apps) describes, then re-run `provision-apps.sh`. Exactly 5 is not enough,
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
init's stamp is missing too: `piri-init.stamp`, or `piri-base-config.applied.toml` on a node that
has not re-run init since the stamp replaced it. The entrypoint writes the stamp once init returns,
so a node that has never got that far holds no proof set. A missing config next to a present stamp
aborts the deploy: init has completed here before, so Piri may still owe a proof. Restore the config, or
`docker stop filone-piri` if the node is being decommissioned.

**Piri logs `WARNING: init failed; serving the existing config version N`.** Piri's entrypoint
re-runs `piri init` whenever one of init's inputs changes: the base config, a `node.env` value init
takes as a flag (public URL, chain endpoint, registrar, PLC directory, operator email), the Postgres
URL, so a rotation of Piri's database password too, the chain RPC token on dev, or a Piri image that
writes a different config version, which a rollback to an older image does as well as an upgrade. It
happens on the next recreate, which `deploy-apps.sh` does behind the proving gate, so an image bump
or such a `node.env` edit costs one init run, not just a restart. A re-run that fails, or does not
finish within 5 minutes (`PIRI_INIT_TIMEOUT` in `node.env`, in seconds; a value that is not a
whole number without leading zeros falls back to 300 with a warning), ends in this warning when it is safe to
carry on: the image writes a different config version, it is the first start since the stamp
replaced the snapshot and the old snapshot still matches the base config, or init timed out. Piri
then serves the config already on disk, which holds its proof set; `N` is that config's version. A
preceding `did not finish within` line means init was killed with SIGKILL (exit 137): usually by the
timeout, but the kernel's OOM killer exits the same way, and `dmesg` on the host tells the two
apart. The first-start case can hide a `node.env` or token change that lands in the same deploy: the
config served lacks it until init next succeeds. Any other failure of a re-run still exits, and
Docker restarts the container into the same init. The lines before the warning in `docker logs
filone-piri` carry init's own error, most often the registrar or chain RPC being unreachable. A kill
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
sudo flock /run/fil-one/deploy.lock sh -c 'scripts/host/pdp-gate.sh \
  && rm /mnt/fil-one/data/piri/piri-init.failed \
  && docker restart filone-piri'
```

Those are dev's checkout and data directory; staging's are `/root/fil-one/infra-nodes` and
`/mnt/data/fil-one/data/piri/`. Deleting the file without
the restart retries on the next start of any kind, gated or not; `deploy-apps.sh` does not recreate
Piri when nothing has changed.

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
