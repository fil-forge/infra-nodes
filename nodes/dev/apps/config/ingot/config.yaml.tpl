# Ingot's config for the dev node.
#
# This file is a secret: it embeds the Postgres DSN and the root S3 credentials.
# Rendered from OpenBao into the root-only tmpfs and mounted read-only, never
# written to a disk that survives a reboot.

# Caddy terminates TLS and forwards here over the filone network; nothing on the
# host reaches this port.
#
# PATH-STYLE ONLY. There is no wildcard certificate for
# <bucket>.s3.us-east-9.latest.dev.filonecontent.com, so a client using
# virtual-host addressing fails TLS before it gets here. Clients set
# force_path_style or addressing_style=path.
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

# Every object's content-encryption key is wrapped under this node's region KEK,
# which lives in the transit engine of the node's own OpenBao and never enters
# this process. The socket is on a bind mount the two containers share; OpenBao
# publishes no port and joins no Docker network.
#
# The token is periodic and provision-regionkey.sh mints it. Nothing inside this
# process renews it, so every reconcile pass on the host does, against a 72h
# period. A lapsed token passes startup and /health and surfaces as a decrypt
# failure on the first GET.
#
# The key name is derived from REGION_LABEL in scripts/host/lib.sh, so this and
# the transit key the provisioning script creates cannot disagree.
regionkey:
  provider: openbao
  openbao:
    address: "unix:///run/openbao/api.sock"
    token: "${INGOT_REGIONKEY_TOKEN}"
    mount: transit
    key: "${FILONE_REGIONKEY_NAME}"

# Where tenant did:plc documents resolve from. Ingot reads the tenant's #wrap
# verification method out of the document and wraps to it, so a tenant whose
# document carries no #wrap key cannot be written to. Central publishes this
# directory for the whole dev stage.
tenantkey:
  plc_directory_url: "${PLC_DIRECTORY_URL}"
