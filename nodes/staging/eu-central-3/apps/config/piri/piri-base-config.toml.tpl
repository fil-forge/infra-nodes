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

# OTLP metrics and traces go to the host's Alloy, reached the same way as Lotus. The host
# Alloy's receiver is configured outside this repository; docs/RUNBOOK.md says
# what it needs.
[[telemetry.metrics]]
endpoint = "host.docker.internal:4318"
insecure = true
publish_interval = "30s"

[[telemetry.traces]]
endpoint = "host.docker.internal:4318"
insecure = true
