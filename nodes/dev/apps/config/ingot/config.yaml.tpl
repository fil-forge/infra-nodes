# Ingot's config for the dev node.
#
# This file is a secret: it embeds the Postgres DSN and the root S3 credentials.
# Rendered from OpenBao into the root-only tmpfs and mounted read-only, never
# written to a disk that survives a reboot.

# Caddy terminates TLS and forwards here over the filone network; nothing on the
# host reaches this port.
#
# PATH-STYLE ONLY. There is no wildcard certificate for
# <bucket>.ingot.dev.forge-sandbox.fil.one, so a client using virtual-host
# addressing fails TLS before it gets here. Clients set force_path_style or
# addressing_style=path.
addr: "0.0.0.0:9000"

# The virtual region this node presents. hilt registers this Ingot under the
# same string and clients sign with it as AWS_REGION; a mismatch in any of the
# three shows up as a signature error that names none of them.
region: ${REGION_LABEL}

data_dir: /data
log_level: info

# Browser origins the S3 listener answers CORS for.
cors_allowed_origins:
  - "https://app.fil.one"
  - "https://app.filone.ai"
  - "https://*.dev.fil.one"

# Break-glass S3 account. Ordinary credentials are minted by hilt per tenant;
# these exist for the case where hilt cannot be reached and someone has to see
# what the gateway is holding.
root_access: "${INGOT_ROOT_ACCESS_KEY}"
root_secret: "${INGOT_ROOT_SECRET_KEY}"

# Ingot signs as this did:web and serves the matching document at
# /.well-known/did.json, over the same listener. The key below is what the
# document publishes and what actually signs; the DID is the name hilt's
# delegation is addressed to, so the two sides agree without central ever
# seeing this key.
identity:
  key_file: /keys/ingot.pem
  service_id: ${INGOT_DID}

# Segment metadata and the blob location registry, in the node's shared
# Postgres. The password matches the one postgres-init set for this role.
postgres_dsn: "postgres://ingot:${INGOT_POSTGRES_PASSWORD}@postgres:5432/ingot?sslmode=disable"

# Forge upload service.
upload_service_url: "${SPRUE_URL}"
upload_service_did: "${SPRUE_DID}"
upload_receipts_url: "${SPRUE_URL}/receipt"

# S3 authorization service. The DID is used verbatim and is not resolved.
auth_service_url: "${HILT_URL}"
auth_service_did: "${HILT_DID}"

# hilt's delegation to this node's Ingot DID, covering /s3/request/authorize and
# the /s3/bucket/* commands. Returned by onboarding and stored in OpenBao,
# because it names a DID that only exists once the node is provisioned.
auth_service_proofs: "/proofs/hilt-ingot-proof.txt"
