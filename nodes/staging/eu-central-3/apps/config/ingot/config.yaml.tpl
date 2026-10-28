addr: "0.0.0.0:9000"
region: ${REGION_LABEL}
data_dir: /data
log_level: info
cors_allowed_origins:
  - "https://staging.fil.one"
  - "https://staging.filone.ai"
  - "https://*.dev.fil.one"
  # Fil One's console on a local stack (Vite on floci, a local AWS emulator),
  # which Fil One's E2E jobs drive.
  - "https://localhost:5173"
identity:
  key_file: /keys/ingot.pem
  service_id: ${INGOT_DID}
postgres_dsn: "postgres://ingot:${INGOT_POSTGRES_PASSWORD}@postgres:5432/ingot?sslmode=disable"
upload_service_url: "${SPRUE_URL}"
upload_service_did: "${SPRUE_DID}"
upload_receipts_url: "${SPRUE_URL}/receipt"
auth_service_url: "${HILT_URL}"
auth_service_did: "${HILT_DID}"
auth_service_proofs: "/proofs/hilt-ingot-proof.txt"

# Swarf's revocation firehose. Hilt publishes a UCAN revocation for every key a
# bucket policy change or key deletion affects; Ingot drops those keys from its
# per-key authorization caches. Without it, a cached key keeps its old
# permissions until the cache entry expires.
revocation_service_url: "${SWARF_URL}"
revocation_service_did: "${SWARF_DID}"
regionkey:
  provider: openbao
  openbao:
    address: "unix:///run/openbao/api.sock"
    token: "${INGOT_REGIONKEY_TOKEN}"
    mount: transit
    key: "${FILONE_REGIONKEY_NAME}"
tenantkey:
  plc_directory_url: "${PLC_DIRECTORY_URL}"
