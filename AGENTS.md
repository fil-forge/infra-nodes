# Agent Guidelines

## Observability

When a change adds or alters something that runs on an appliance, decide how
on-call would know it had broken, and add that in the same PR where it is
useful: logs, metrics, a line in `docs/observability.md`, and an alert or
dashboard panel in fil-forge/infra-central. Skip it for changes nothing
operational depends on. "Adding a signal" in `docs/observability.md` says how
to do each.
