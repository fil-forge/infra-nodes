addr: "0.0.0.0:9000"
region: ${REGION_LABEL}
data_dir: /data
log_level: info
cors_allowed_origins:
  - "https://app.fil.one"
  - "https://app.filone.ai"
root_access: "${INGOT_ROOT_ACCESS_KEY}"
root_secret: "${INGOT_ROOT_SECRET_KEY}"
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
regionkey:
  provider: openbao
  openbao:
    address: "unix:///run/openbao/api.sock"
    token: "${INGOT_REGIONKEY_TOKEN}"
    mount: transit
    key: "${FILONE_REGIONKEY_NAME}"
tenantkey:
  plc_directory_url: "${PLC_DIRECTORY_URL}"
