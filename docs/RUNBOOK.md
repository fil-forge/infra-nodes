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
so check it with a WebSocket upgrade request; the token goes in through a file descriptor, so it
never appears in a command line:

```sh
token="$(docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$(cat /etc/fil-one/bao-token)" \
  filone-openbao bao kv get -mount=filone -field=chain_rpc_token external)"
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
     docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$(cat /etc/fil-one/bao-token)" \
       filone-openbao bao "$@"
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
  address="$(docker exec -e BAO_ADDR=http://127.0.0.1:8200 \
    -e BAO_TOKEN="$(cat /etc/fil-one/bao-token)" filone-openbao \
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

## Re-onboarding after identity loss

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
for a new wrapping token.

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

Piri's proving rules in infra-central's `terraform/envs/grafana/alerts.tf` link here. Each says how
soon to act. Three page, because waiting overnight can make a loss permanent. The other three can
wait until the next day: two cost about one proving period's payment a day (24 hours on mainnet)
and lose nothing more once the cause is fixed, and the third reports a loss that has already
happened. The severity definitions are in infra-central's `docs/observability.md`.

Dev and staging each run three Piris, `piri-0` to `piri-2`. The proving alerts are grouped by node,
not by Piri, so check each one. The commands below take the Piri's number in `n`, so set it first,
for example `n=0`: its container is `filone-piri-$n` and its database `piri_$n`. If `n` is unset,
these commands fail rather than reach the wrong Piri. Staging may still hold a database named `piri`
from when it ran one Piri, now `piri-0`; nothing reads it any more.

Most checks run inside the Piri container, from its data directory: `docker exec -it -w /data/piri
filone-piri-$n sh`. There, `piri status` checks the node and `piri client pdp proofset state` its
proof set, both reading `piri-config.toml` from the current directory, which also names the proof
set; add `--proof-set <id>` for another one. Run from anywhere else, they need `--config
/data/piri/piri-config.toml`, and without it stop on a config error before reaching the node.
Curio's task logs are in the container's output, named by task: `docker logs "filone-piri-${n:?}"
2>&1 | grep -e PDPv0_Prove -e 'No such container'`, or `PDPv0_ProvPeriod` for scheduling. The
`${n:?}` and the second pattern are there because `grep` would otherwise swallow docker's error for
an unset or wrong `n` and print nothing, which looks like a Prove task that never ran.

#### Piri's chain head is stale

**Act within about three hours.** Uploads and reads keep working, but Piri cannot add new pieces to
its data set on chain. Each batch of pieces gets about 3.5 hours of retries if the chain endpoint is
unreachable, and 6.9 if it answers but is stale. After that, Piri gives up on the batch and never
retries it ([FIL-1508](https://linear.app/filecoin-foundation/issue/FIL-1508)). The batch then waits
for the fix below.

Dev and staging read the chain from Chain.Love (`LOTUS_RPC_URL` in `node.env`), not from a Lotus of
their own. `piri status` shows no chain head, but `piri client pdp proofset state` does: its Current
Epoch is Chain.Love's head, read when the command runs. A Current Epoch of 0 means the proof set is
not initialised yet, not that Chain.Love is behind. Compare it with Calibration's current height on
a block explorer. If it is behind, Chain.Love is lagging, and there is nothing to fix on the node;
wait for it to catch up. If the command fails with `failed to get chain head`, Piri cannot reach
Chain.Love (any other error is not the chain endpoint's): check the token as in "A Piri crash-loops
on the chain endpoint" above, using the key check under [The eu-central-3 staging appliance on
Servers.com](#the-eu-central-3-staging-appliance-on-serverscom), which works on dev too. If
Chain.Love is current while the alert still fires, Piri's own subscription is stale. Piri
resubscribes on its own after five minutes without a new tipset, so a head that stays old for longer
than that needs a restart of Piri: `docker restart filone-piri-$n`. The proving-window gate that
deploys wait for doesn't apply here, since Piri isn't proving without a head.

Once the head moves again, look for stranded batches, and free them if there are any. The next
AddRoots run picks them up.

```sh
docker exec filone-platform-postgres-1 psql -U admin -d "piri_$n" -c "
  SELECT count(DISTINCT s.add_task_id) AS batches, count(*) AS roots
  FROM curio.pdp_root_submissions s
  WHERE s.add_task_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM curio.harmony_task h WHERE h.id = s.add_task_id)"

docker exec filone-platform-postgres-1 psql -U admin -d "piri_$n" -c "
  UPDATE curio.pdp_root_submissions s SET add_task_id = NULL
  WHERE s.add_task_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM curio.harmony_task h WHERE h.id = s.add_task_id)"
```

#### Piri is reporting but has no chain head

**Act within about three hours**, for the reason above. Piri has not seen a single tipset since it
started, usually because the chain endpoint was unreachable then. `piri client pdp proofset state`
failing with `failed to get chain head` confirms it still is; check the endpoint and token as in "A
Piri crash-loops on the chain endpoint" above. Then restart Piri (`docker restart filone-piri-$n`),
and once it has a head, check for stranded batches as above.

#### Piri proving is failing

**Act now.** The contract has rejected a proving transaction for a proof set. Curio gives up on a
proof set for good on its fifth rejection without a successful proof in between. The retries wait
100, 200, 400 and 800 epochs, so the fifth can come 12.5 hours after the first. Nothing on the node
brings the proof set back after that.

Find the rejection in the `PDPv0_Prove` or `PDPv0_ProvPeriod` logs, and check the proof set's state.
The revert reason says what the contract refused. A rejection that says the data set's payment has
ended or been terminated makes Curio give up at once, and the next alert is "Piri proof set is
unrecoverable".

#### Piri's proving period has not advanced

**Act within a day.** A proof set's challenge window has closed and Piri has not scheduled the
next one, without a failure to explain it. Each day it stays stuck costs that day's proving period,
and nothing more: once scheduling runs again, Curio takes the next window from the contract and
carries on.

The usual causes are a chain head that has stopped moving, which pages as "Piri's chain head is
stale", and Piri's task engine not running. Run `piri status`, check the proof set's state, and read
the `PDPv0_ProvPeriod` logs for whether scheduling ran.

One cause can lose more without paging: one that also stops AddRoots while the head keeps moving,
such as an owner wallet without FIL for gas. Each Piri has its own owner wallet, in OpenBao at
`piri-$n`. Check its balance, and fund it as [step 6](#6-onboarding-then-the-apps) describes if it's
low. If the logs show AddRoots failing too, check for stranded batches as in [Piri's chain head is
stale](#piris-chain-head-is-stale) once it's fixed.

#### Piri's Prove task has not run in 1.5 proving periods

**Act within a day.** No proof has gone out for one and a half proving periods, so at least one
period's payment is already lost, and each further day loses another. Proving resumes on its own
once the cause is fixed. Most causes that can lose more than that page on their own: rejected proofs
as "Piri proving is failing", and a stalled head as "Piri's chain head is stale". Check `piri
status`, the balance of the Piri's owner wallet at `piri-$n` (fund it as [step
6](#6-onboarding-then-the-apps) describes), and each proof set's state, and read the `PDPv0_Prove`
logs for why no run finished. If AddRoots is failing too, check for stranded batches as in [Piri's
chain head is stale](#piris-chain-head-is-stale) once the cause is fixed.

#### Piri proof set is unrecoverable

**Act within a day.** Curio has given up on a proof set and will not prove it again. The loss has
already happened, so there is nothing to race. Find why in Piri's logs, and record it on the
incident; what to do with the data set is decided outside this runbook.

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
when `piri-base-config.applied.toml` is missing too, because init writes that file last and a node
that has never got that far holds no proof set. A missing config next to a present snapshot aborts
the deploy: init has completed here before, so Piri may still owe a proof. Restore the config, or
`docker stop filone-piri-<n>` if that Piri is being decommissioned.

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
