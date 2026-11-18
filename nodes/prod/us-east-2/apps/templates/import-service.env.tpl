# Secret environment for the import service, rendered from the node's OpenBao
# (path import-service) into /run/fil-one/secrets/import-service.env by
# deploy-import.sh. Single-quoted, so a DSN in keyword form keeps its spaces;
# deploy-import.sh refuses a value holding a quote or a line break.
IST1_PACK_LEDGER='${IMPORT_SERVICE_LEDGER_DSN}'
IST1_PACK_S3_ACCESS_KEY_ID='${IMPORT_SERVICE_S3_ACCESS_KEY_ID}'
IST1_PACK_OPENBAO_ROLE_ID='${IMPORT_SERVICE_KEYS_ROLE_ID}'
IST1_PACK_OPENBAO_SECRET_ID='${IMPORT_SERVICE_KEYS_SECRET_ID}'
