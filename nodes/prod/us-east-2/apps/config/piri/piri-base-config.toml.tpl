# Piri's base config for the prod/us-east-2 node. `piri init` merges it with
# what it discovers and writes the node's real config into the data directory;
# see the dev node's base config.
#
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

# No indexer and no IPNI, as on dev and staging.
[ucan.services.upload]
did = "${SPRUE_DID}"
url = "${SPRUE_URL}"

# OTLP metrics and traces go to the platform project's Alloy, on the filone
# network, as on dev. `environment` becomes the deployment.environment.name
# resource attribute.
[telemetry]
environment = "${STAGE}"

[[telemetry.metrics]]
endpoint = "alloy:4318"
insecure = true
publish_interval = "30s"

[[telemetry.traces]]
endpoint = "alloy:4318"
insecure = true
