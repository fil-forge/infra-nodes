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
- **Metrics.** A service that pushes OTLP, as Piri does, needs only to send it
  to the `apps` receiver in `nodes/dev/platform/config/alloy/config.alloy`. One
  that is scraped needs a scrape there, routed through a `prometheus.relabel`
  that sets `service_name` (`appliance-<stage>-<region>-<service>`) and
  `instance`, as the host and Caddy ones do; `appliance`, `node` and `region`
  come from the writer's `external_labels`. On staging, `service_name` is what
  keeps a series inside the appliance's queries and rules, so add the same
  requirement to the staging section of `docs/RUNBOOK.md`. A host-side signal,
  such as a timer that has to keep running, can follow the deploy stamp: a
  textfile-collector gauge written by `scripts/host/lib.sh`.
- **Docs.** Add new logs and metrics, with an example query, to
  `docs/observability.md`.
- **Alerts and dashboard panels** for appliances live in
  fil-forge/infra-central, under `terraform/envs/grafana/`: the Forge Regions
  rule groups and the `forge-regions` dashboard. Open a companion PR there, or
  say in this PR that one is needed.
