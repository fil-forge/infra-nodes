# Agent Guidelines

## Observability

When a change adds or alters something that runs on an appliance, decide how
on-call would know it had broken, and add that in the same PR where it is
useful: logs, metrics, a line in `docs/observability.md`, and an alert or
dashboard panel in fil-forge/infra-central. Skip it for changes nothing
operational depends on. "Adding a signal" in `docs/observability.md` says how
to do each.

## CI scripts

A script that only one workflow runs lives in `scripts/ci/<workflow>/`, where
`<workflow>` is the workflow's file name without `.yml`: the helpers of
`.github/workflows/test-nodes.yml` are `scripts/ci/test-nodes/select.sh`,
`report.sh` and so on. A script that several workflows share, or that a person
also runs from a terminal, such as `smoke-test.sh` or `e2e-test.sh`, stays
directly in `scripts/ci/`.

A workflow step longer than a few lines of shell goes in such a script rather
than in its `run:` block, so `make check-shell` lints it.
