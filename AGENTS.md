# Agent Guidelines

## Observability

When a change adds or alters something that runs on an appliance, decide how
on-call would know it had broken, and add that in the same PR where it is
useful. Skip it for changes nothing operational depends on.
`docs/observability.md` describes what ships to Grafana and under which labels.

- **Logs.** Container stdout and stderr ship without any extra work, under the
  labels in `docs/observability.md`. Dev ships the whole host journal, but
  staging ships only the reconcile service's unit. The staging host's Alloy
  config lives outside this repository, so for a new host service there, add
  what it must ship to the staging section of `docs/RUNBOOK.md` and say in the
  PR that the host's config needs the change.
- **Metrics.**
  - *Pushed over OTLP*, as Piri does: the service sets `service.name` to its
    Compose service name, or to the name its replicas share (dev's `piri-0` to
    `piri-2` all report `piri`, told apart by `service.instance.id`), and
    `service.namespace="forge"`, and sends to Alloy on port 4318, at
    `alloy:4318` on dev and `host.docker.internal:4318` on staging (configure
    it as Ingot's entry in each stage's `apps/compose.yml` does). Neither Alloy then needs a change; on staging, a series without that
    namespace is dropped.
  - *Scraped, on dev*: add a scrape to
    `nodes/dev/platform/config/alloy/config.alloy`, routed through a
    `prometheus.relabel` that sets `service_name` (built as
    `sys.env("SERVICE_NAME_PREFIX") + "-<service>"`) and `instance`, as the
    host and Caddy ones do. `appliance`, `node` and `region` come from the
    writer's `external_labels`.
  - *Scraped, on staging*: only `appliance` is on the writer, so add the scrape
    to the staging section of `docs/RUNBOOK.md` with rules that set
    `service_name`, `node`, `region` and `instance` as the existing staging
    rules do, and say in the PR that the host's Alloy config needs it.
  - *Host-side signals*, such as a timer that has to keep running, can follow
    the deploy stamp: a textfile-collector gauge written by
    `scripts/host/lib.sh`.
- **Docs.** Add new logs and metrics, with an example query, to
  `docs/observability.md`.
- **Alerts and dashboard panels** for appliances live in
  fil-forge/infra-central, under `terraform/envs/grafana/`: the Forge Regions
  rule groups and the `forge-regions` dashboard. Open a companion PR there, or
  say in this PR that one is needed.
