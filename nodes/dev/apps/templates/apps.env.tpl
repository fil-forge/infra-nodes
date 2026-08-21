# Secret environment for the apps compose project.
#
# Rendered from the node's OpenBao into /run/filone/secrets/apps.env, 0400 root,
# on a tmpfs.
#
# Two values. Ingot takes its DSN from its own rendered YAML, and everything
# else the two services need is either non-secret (node.env) or a file (the
# keys, the configs, the proof).

PIRI_POSTGRES_PASSWORD=${PIRI_POSTGRES_PASSWORD}

# Piri's bearer token for the chain RPC provider.
CHAIN_RPC_TOKEN=${CHAIN_RPC_TOKEN}
