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

# Application metrics to the host-owned Alloy, which relabels them and forwards
# to Grafana Cloud. Piri exports nowhere unless a collector is named here.
#
# The endpoint is a host and port: no scheme and no path, because Piri appends
# /v1/metrics itself, and OTLP over HTTP is 4318. This host's Alloy is a
# systemd service rather than a container, reached the same way Lotus is; the
# runbook's staging section says what its OTLP receiver has to bind to.
[telemetry]
environment = "${STAGE}"

[[telemetry.metrics]]
endpoint = "host.docker.internal:4318"
insecure = true
publish_interval = "30s"
