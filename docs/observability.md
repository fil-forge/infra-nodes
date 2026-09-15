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
Postgres, and on dev also Caddy and Alloy itself. On staging, Caddy is the host's, and the runtime
log it writes for itself ships under the `-caddy` service name. The host journal too: on dev the whole journal,
which is where cloud-init, Docker and a failed unit are legible; on staging only the reconcile
service's unit, since the rest of that host's journal is not the appliance's.

**Metrics.** The host's CPU, disk I/O, filesystems, load and memory from a node exporter, scraped
every minute, plus the deploy stamp the reconcile timer writes on every pass. Caddy's request
metrics, also every minute: counts, durations and sizes per site, handler, method and status code,
which is where the public error rate is read from. Staging also ships per-container CPU, memory,
network and I/O from cAdvisor every fifteen seconds. Dev does not: the Alloy container has no cgroup
mount, and container health there is read from the journal and the deploy stamp instead.

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

`appliance`, `node` and `region` are on every stream and every series an appliance ships, whichever
node it is. `service_name` is on the journal, the host metrics and every container Compose started.
A container started by hand with `docker run` has no Compose service, so its logs ship under
`job="docker"` and `container=<name>` with no `service_name`.

| Label          | Example                          | Meaning                                                                                                                                                        |
| -------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `appliance`    | `dev-us-east-9`                  | `<stage>-<region>`. One matcher for everything the appliance ships. On staging it is also on the host's other metrics, since it sits on the metrics writer.   |
| `node`         | `dev`, `staging`                 | The box. `FILONE_NODE` in `node.env`.                                                                                                                          |
| `region`       | `us-east-9`, `eu-central-3`      | `REGION_LABEL` in `node.env`.                                                                                                                                  |
| `service_name` | `appliance-dev-us-east-9-piri`   | `appliance-<stage>-<region>-<service>`. `<service>` is the Compose service name, or `host` for the journal and the host metrics. Two nodes in one stage and region share it and are told apart by `node`. Absent on a container started by hand; select that one by `container`. |

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

### Caddy

Both nodes ship Caddy's runtime log as JSON: certificate issuance and renewal, TLS cache
maintenance, config loads, the per-request error entries Caddy writes when an upstream fails, and
on dev the Compose healthcheck reading the admin API every fifteen seconds, which is most of dev's
lines. No node has access logs. On dev the stream is the Caddy container's stdout. On staging it is
`/root/storacha/logs/caddy/caddy.log`, which the host Caddy writes and rolls itself.
Most runtime entries name no site, so the staging stream covers every site that Caddy serves,
Guppy's and Curio's included. The per-request error entries do name one, in the `request.host`
field, which `| json` flattens to `request_host`.

Caddy on every node, without the dev healthcheck:

```logql
{service_name=~"appliance-.*-caddy"} | json | logger != "admin.api"
```

Requests to a FilOne site on staging that Caddy could not serve, such as a 502 while Piri restarts:

```logql
{service_name="appliance-staging-eu-central-3-caddy"} | json | logger =~ "http.log.error.*" | request_host =~ "piri-0.staging.fil-forge.com(:443)?"
```

Certificate activity for a FilOne hostname on staging:

```logql
{service_name="appliance-staging-eu-central-3-caddy"} | json | logger =~ "tls.*|http.acme_client" |= "s3.eu-central-3.staging.filonecontent.com"
```

Warnings and errors from Caddy on every node:

```logql
{service_name=~"appliance-.*-caddy"} | json | level =~ "warn|error"
```

### Log labels

| Label            | Example                     | On which streams                                                                                                      |
| ---------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `container`      | `filone-piri`               | Container logs. The Docker container name.                                                                            |
| `compose_project`| `filone-apps`               | Container logs on dev. `filone-apps` or `filone-platform`.                                                            |
| `unit`           | `filone-reconcile.service`  | Journal lines. The systemd unit that wrote the line.                                                                  |
| `job`            | `docker`, `journal`         | Dev streams. Staging container logs carry no `job`; its reconcile journal carries the Alloy component name.           |
| `hostname`       | `curio`                     | Staging streams. The host's own label, shared with everything else that Alloy ships.                                 |
| `service`, `stream` | `piri`, `stderr`         | Staging container logs. The host's own labels: bare Compose service name and the Docker stream. The staging Caddy log carries `service="caddy"` and the tailed file's path as `filename`, and no `stream`. |
| `detected_level` | `info`                      | Loki, parsed from the line.                                                                                           |

Select by `appliance`, `service_name`, `node`, `container` or `unit`. The others differ between nodes, so a query
built on them works on one node only.

## Metrics

Metric names are the node exporter's `node_*` family, cAdvisor's `container_*` family on staging,
Caddy's `caddy_http_*` family, and `deploy_last_success_timestamp`. Every series carries the four
labels above plus `instance`, which is the node name, and `job`, which is `integrations/unix` for
the host, `cadvisor` for containers and `caddy` for Caddy.

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

### Caddy requests

Caddy records every request it serves. The counters and histograms carry `server`, `handler`,
`method` and `code`, plus `host`, which is the site the request was for. `caddy_http_requests_total`
has no `code` label, so a status-code query reads the histogram's count instead.

| Label     | Example                                | Meaning                                                                                                              |
| --------- | -------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `host`    | `piri-0.latest.dev.fil-forge.com`      | The hostname the request was for. On dev any other name is counted under `_other`. On staging the host Caddy is 2.9.1, which records every name it sees, and the scrape keeps only the appliance's two. |
| `handler` | `reverse_proxy`, `file_server`         | The handler that produced the response. `file_server` is the node status document; the rest is proxied to Piri or Ingot. |
| `server`  | `public`                               | The listener. On dev, `public` is :443 and `remaining_auto_https_redirects` is the :80 redirect Caddy adds itself.  |
| `code`    | `502`                                  | The response status. A 502 is Caddy failing to reach the upstream; a 500 came from Piri or Ingot itself.             |

The dev appliance's 5xx responses as a share of everything it served, over five minutes:

```promql
sum(rate(caddy_http_request_duration_seconds_count{appliance="dev-us-east-9", code=~"5.."}[5m]))
/
sum(rate(caddy_http_request_duration_seconds_count{appliance="dev-us-east-9"}[5m]))
```

The same split by site, so Piri and Ingot each get a line:

```promql
sum by (host) (rate(caddy_http_request_duration_seconds_count{appliance="dev-us-east-9", code=~"5.."}[5m]))
/
sum by (host) (rate(caddy_http_request_duration_seconds_count{appliance="dev-us-east-9"}[5m]))
```

5xx responses per second, by status code and handler, which separates a proxy that cannot reach
its upstream from an upstream returning errors:

```promql
sum by (appliance, host, handler, code) (rate(caddy_http_request_duration_seconds_count{service_name=~"appliance-.*-caddy", code=~"5.."}[5m]))
```

On staging, Caddy belongs to the host and serves sites that are not the appliance's. The host's
Alloy ships only the series for the appliance's two hostnames, plus Caddy's own process series,
which carry no `host`, all under `service_name="appliance-staging-eu-central-3-caddy"`:

```promql
sum by (host) (rate(caddy_http_request_duration_seconds_count{node="staging", host=~"piri-0.staging.fil-forge.com|s3.eu-central-3.staging.filonecontent.com", code=~"5.."}[5m]))
/
sum by (host) (rate(caddy_http_request_duration_seconds_count{node="staging", host=~"piri-0.staging.fil-forge.com|s3.eu-central-3.staging.filonecontent.com"}[5m]))
```

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

The Caddy scrape has its own `up`. A zero here with the host scrape at one means Alloy is running
and Caddy's metrics listener is not answering:

```promql
up{job="caddy"}
```

No series at all for a node means Alloy is not pushing. On dev, that is the Alloy container: check
it on the box with `docker logs filone-platform-alloy-1` (the Compose default name for the `alloy` service), or from Grafana with
`{service_name="appliance-dev-us-east-9-alloy"}`, which arrives only while the Loki push still
works. On staging it is the host's `alloy` systemd service, `journalctl -u alloy`. The journal and
container streams have no equivalent of `up`; a node whose metrics arrive and whose logs do not has
a Loki push problem, and Alloy logs that as a write error.

Dev picks up an Alloy config change on the next reconcile pass after it merges: the platform deploy
hashes the file's content along with the service definition and recreates the Alloy container, and
only that one, inside the proving-window gate. Staging picks one up
after the operator restarts the host's Alloy; a reload is not enough for the container log labels,
as the runbook explains.
