# Finding an appliance's logs and metrics in Grafana

Every appliance ships its host journal, its container logs and its host metrics to the Filecoin
Foundation Grafana Cloud stack through Grafana Alloy. On dev, Alloy is a platform container and its
config is `nodes/dev/platform/config/alloy/config.alloy`. On staging, the host owns Alloy and its
config lives outside this repository; the staging section of the [runbook](RUNBOOK.md) says what
that config has to contain. This page says what arrives, under which labels, and the queries that
find it. Why the pipeline is shaped this way is in the [telemetry section of the initial
design](decisions/2026-08-initial-design.md#telemetry).

## What ships

**Logs.** Every line each FilOne container writes to stdout or stderr: Piri, Ingot, OpenBao,
Postgres, and on dev also Caddy and Alloy itself. The host journal too: on dev the whole journal,
which is where cloud-init, Docker and a failed unit are legible; on staging only the reconcile
service's unit, since the rest of that host's journal is not the appliance's.

**Metrics.** The host's CPU, disk I/O, filesystems, load and memory from a node exporter, scraped
every minute, plus the deploy stamp the reconcile timer writes on every pass. Staging also ships
per-container CPU, memory, network and I/O from cAdvisor every fifteen seconds. Dev does not: the
Alloy container has no cgroup mount, and container health there is read from the journal and the
deploy stamp instead.

**Not shipped.** Piri's and Ingot's own application metrics; the network interface collector, which
inside the Alloy container would report the container's namespace rather than the host's; traces.
Piri exports traces over OTEL to the Forge collector, which is a separate pipeline.

## Where to look

| Signal  | Data source                            | Query language |
| ------- | -------------------------------------- | -------------- |
| Logs    | `grafanacloud-filecoinfoundation-logs` | LogQL          |
| Metrics | `grafanacloud-filecoinfoundation-prom` | PromQL         |

Both are in Explore. Pick the data source, paste a query below, set the time range.

## Labels

Four labels are on every stream and every series an appliance ships, whichever node it is.

| Label          | Example                          | Meaning                                                                                                                                                        |
| -------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `appliance`    | `dev-us-east-9`                  | `<stage>-<region>`. One matcher for everything the appliance ships. On staging it is also on the host's other metrics, since it sits on the metrics writer.   |
| `node`         | `dev`, `staging`                 | The box. `FILONE_NODE` in `node.env`.                                                                                                                          |
| `region`       | `us-east-9`, `eu-central-3`      | `REGION_LABEL` in `node.env`.                                                                                                                                  |
| `service_name` | `appliance-dev-us-east-9-piri`   | `appliance-<stage>-<region>-<service>`. `<service>` is the Compose service name, or `host` for the journal and the host metrics. Two nodes in one stage and region share it and are told apart by `node`. |

## Logs

Everything the staging appliance ships, host journal and containers together:

```logql
{appliance="staging-eu-central-3"}
```

Piri on dev:

```logql
{service_name="appliance-dev-us-east-9-piri"}
```

Piri on every node, told apart by the `node` label:

```logql
{service_name=~"appliance-.*-piri"}
```

Everything an appliance's containers wrote, errors only:

```logql
{node="staging", container=~"filone-.*"} |= "ERROR"
```

The reconcile timer's own output, which is where a failed deploy is legible:

```logql
{node="dev", unit="filone-reconcile.service"}
```

The whole dev journal, every unit, for a boot or a Docker problem:

```logql
{service_name="appliance-dev-us-east-9-host"}
```

### Log labels

| Label            | Example                     | On which streams                                                                                                      |
| ---------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `container`      | `filone-piri`               | Container logs. The Docker container name.                                                                            |
| `compose_project`| `filone-apps`               | Container logs on dev. `filone-apps` or `filone-platform`.                                                            |
| `unit`           | `filone-reconcile.service`  | Journal lines. The systemd unit that wrote the line.                                                                  |
| `job`            | `docker`, `journal`         | Dev streams. Staging container logs carry no `job`; its reconcile journal carries the Alloy component name.           |
| `hostname`       | `curio`                     | Staging streams. The host's own label, shared with everything else that Alloy ships.                                 |
| `service`, `stream` | `piri`, `stderr`         | Staging container logs. The host's own labels: bare Compose service name and the Docker stream.                       |
| `detected_level` | `info`                      | Loki, parsed from the line.                                                                                           |

Select by `appliance`, `service_name`, `node`, `container` or `unit`. The others differ between nodes, so a query
built on them works on one node only.

## Metrics

Metric names are the node exporter's `node_*` family, cAdvisor's `container_*` family on staging,
and `deploy_last_success_timestamp`. Every series carries the four labels above plus `instance`,
which is the node name, and `job`, which is `integrations/unix` for the host and `cadvisor` for
containers.

Free space on the dev appliance's filesystems:

```promql
node_filesystem_avail_bytes{node="dev"}
```

Five-minute load across every appliance, one series per node:

```promql
node_load5{service_name=~"appliance-.*-host"}
```

Memory used, as a fraction, per node:

```promql
1 - node_memory_MemAvailable_bytes{job="integrations/unix", node!=""} / node_memory_MemTotal_bytes
```

Piri's working set on staging, from cAdvisor:

```promql
container_memory_working_set_bytes{service_name="appliance-staging-eu-central-3-piri"}
```

Every FilOne container's CPU on staging, per service:

```promql
sum by (service_name) (rate(container_cpu_usage_seconds_total{node="staging", service_name!=""}[5m]))
```

cAdvisor also reports the host's other containers under `job="cadvisor"`. The `service_name`
matcher keeps the appliance's ones. On staging, `appliance` alone is not that filter: it sits on
the metrics writer, so the host's Lotus, Sophon and other series carry it too, and a query for the
appliance's own metrics adds `service_name=~"appliance-.*"`.

### The deploy stamp

`deploy_last_success_timestamp` is the Unix time of the last successful pass of each project, with
a `project` label of `apps`, `platform` or `reconcile`. `reconcile` moves on every pass, whether
anything deployed or not; `apps` and `platform` move only when that project deployed. The timer
runs every five minutes, so a `reconcile` stamp older than fifteen minutes means the node has
stopped reconciling:

```promql
time() - deploy_last_success_timestamp{project="reconcile"} > 15 * 60
```

When each project last deployed, per node:

```promql
deploy_last_success_timestamp{project=~"apps|platform"}
```

## Is the pipeline itself healthy

Alloy scrapes its own node exporter, so `up` says whether the host metrics scrape is working, one
series per node:

```promql
up{service_name=~"appliance-.*-host"}
```

No series at all for a node means Alloy is not pushing. On dev, that is the Alloy container: check
it on the box with `docker logs filone-platform-alloy-1` (the Compose default name for the `alloy` service), or from Grafana with
`{service_name="appliance-dev-us-east-9-alloy"}`, which arrives only while the Loki push still
works. On staging it is the host's `alloy` systemd service, `journalctl -u alloy`. The journal and
container streams have no equivalent of `up`; a node whose metrics arrive and whose logs do not has
a Loki push problem, and Alloy logs that as a write error.

Dev picks up an Alloy config change on the next reconcile pass after it merges. Staging picks one up
after the operator restarts the host's Alloy; a reload is not enough for the container log labels,
as the runbook explains.
