# Agent Guidelines

## Observability

When a change adds or alters something that runs on an appliance, decide how
on-call would know it had broken, and add that in the same PR where it is
useful. `docs/observability.md` describes what ships to Grafana and under
which labels.

- **Logs.** Container stdout and stderr ship without any extra work, under the
  labels in `docs/observability.md`. Dev ships the whole host journal, but
  staging ships only the reconcile service's unit, so a new host service on
  staging has to be added to that host's Alloy config.
- **Metrics.** If a new service exports metrics, add a scrape for it to
  `nodes/dev/platform/config/alloy/config.alloy`. The staging host owns its own
  Alloy config, so also add the scrape to what the staging section of
  `docs/RUNBOOK.md` says that config must contain. Every series needs the
  `appliance`, `node` and `region` labels. A host-side signal, such as a timer
  that has to keep running, can follow the deploy stamp: a textfile-collector
  gauge written by `scripts/host/lib.sh`.
- **Docs.** Add new logs and metrics, with an example query, to
  `docs/observability.md`.
- **Alerts and dashboard panels** for appliances live in
  fil-forge/infra-central, under `terraform/envs/grafana/`: the Forge Regions
  rule groups and the `forge-regions` dashboard. Open a companion PR there, or
  say in this PR that one is needed.
