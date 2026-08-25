# The node's OpenBao.
#
# Committed, so it carries no secret. The one credential this needs, the token
# that authenticates to the central OpenBao, arrives as VAULT_TRANSIT_SEAL_TOKEN
# from the 0400 file provision-platform.sh writes when it exchanges the
# operator's wrapping token at central.

# Raft on the control-plane volume.
#
# The alternative, storing in the node's Postgres, deadlocks on a VM: OpenBao
# has to be up before anything can read a secret, and Postgres's own password is
# one of those secrets. infra-central runs the Postgres backend because Fargate
# has no durable disk. This box has one.
#
# /openbao/file rather than a path of our own: the image's entrypoint chowns
# that directory to the `openbao` user before it drops to it, so the bind mount
# cloud-init creates root-owned becomes writable by the server. A custom path
# would stay root-owned and raft could not create its files there.
storage "raft" {
  path    = "/openbao/file"
  node_id = "filone-node"
}

# Loopback inside the container, and the container publishes no port. Nothing
# outside this box can reach the API, and nothing inside it can either except
# root, through `docker exec`.
#
# TLS is disabled because the connection never leaves the container's own
# network namespace; a certificate here would protect a loopback hop and cost a
# renewal to forget.
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = "true"
}

# Auto-unseal against the central OpenBao. The node holds no unseal key and no
# operator types one: the seal key is encrypted under a transit key that only
# central can decrypt with, so revoking this node's token at central means the
# next restart of this container comes back sealed and serving nothing.
#
# Mounts cannot nest, so per-node separation is in the key name rather than a
# sub-path, and the node's policy grants encrypt and decrypt on this key alone.
seal "transit" {
  address    = "https://ssm.dev.forge-sandbox.fil.one"
  mount_path = "transit"
  key_name   = "appliance-unseal-us-east-9"
}

# The raft store holds one node and always will. Without this, OpenBao waits for
# peers that are never coming.
cluster_addr = "http://127.0.0.1:8201"
api_addr     = "http://127.0.0.1:8200"

# The container has no swap to leak into and mlock needs a capability that would
# otherwise have to be granted to it.
disable_mlock = true

ui = false
