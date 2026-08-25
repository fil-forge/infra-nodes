# Piri's base config for the dev node.
#
# "Base" is Piri's own term: the operator supplies this, `piri init` merges it
# with what it discovers and writes the node's real config next to the data
# directory. Everything the node learns at init — its DID, its proof set, its
# public URL — is absent here on purpose.
#
# Rendered from node.env into the secrets tmpfs. No value in it is secret; it
# goes to the tmpfs because that is where the deploy scripts render, and one
# rendering path is easier to reason about than two.

[pdp]
chain_id = "${CHAIN_ID}"

# The address the central signing service pays from. Funding it is
# infra-central's `make fund-payer STAGE=dev`; this node never holds the money.
payer_address = "${PAYER_ADDRESS}"

[pdp.signing_service]
did = "${SIGNING_SERVICE_DID}"
url = "${SIGNING_SERVICE_URL}"

# Calibration testnet proxy contracts. Same addresses infra-central's dev stage
# runs against.
[pdp.contracts]
verifier = "${PDP_VERIFIER_ADDRESS}"
provider_registry = "${SERVICE_PROVIDER_REGISTRY_ADDRESS}"
service = "${FWSS_ADDRESS}"
service_view = "${FWSS_VIEW_ADDRESS}"
payments = "${FILECOIN_PAY_ADDRESS}"
usdfc_token = "${USDFC_TOKEN_ADDRESS}"

# Where Piri uploads to. There is no [ucan.services.indexer] block and no
# ipni_announce_urls because no indexing service is deployed: with both omitted
# Piri skips claim caching and IPNI announcements, and with them present
# blob/accept fails trying to POST to a service that is not there.
[ucan.services.upload]
did = "${SPRUE_DID}"
url = "${SPRUE_URL}"
