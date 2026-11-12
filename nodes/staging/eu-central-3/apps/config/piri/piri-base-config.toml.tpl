# The Postgres URL is not here: the entrypoint passes it to `piri init` from
# PIRI_DB_POSTGRES_URL in compose.yml, and its pool_max_conns parameter sizes
# the PDP pipeline's connection pool. The entrypoint hashes init's arguments
# with this file, so changing that URL re-runs init as a change here does.

[pdp]
chain_id = "${CHAIN_ID}"
payer_address = "${PAYER_ADDRESS}"

[pdp.signing_service]
did = "${SIGNING_SERVICE_DID}"
url = "${SIGNING_SERVICE_URL}"

[pdp.contracts]
verifier = "${PDP_VERIFIER_ADDRESS}"
provider_registry = "${SERVICE_PROVIDER_REGISTRY_ADDRESS}"
service = "${FWSS_ADDRESS}"
service_view = "${FWSS_VIEW_ADDRESS}"
payments = "${FILECOIN_PAY_ADDRESS}"
usdfc_token = "${USDFC_TOKEN_ADDRESS}"

# Staging has no Indexer/IPNI dependency.
[ucan.services.upload]
did = "${SPRUE_DID}"
url = "${SPRUE_URL}"

# OTLP metrics and traces go to the host's Alloy, through the Docker host
# gateway that compose's extra_hosts maps. The host Alloy's receiver is
# configured outside this repository; docs/RUNBOOK.md says what it needs.
# `environment` becomes the deployment.environment.name resource attribute, and
# so the deployment_environment_name label on target_info. Piri otherwise takes
# it from the configured network, which a base-config node has none of.
[telemetry]
environment = "${STAGE}"

[[telemetry.metrics]]
endpoint = "host.docker.internal:4318"
insecure = true
publish_interval = "30s"

[[telemetry.traces]]
endpoint = "host.docker.internal:4318"
insecure = true
