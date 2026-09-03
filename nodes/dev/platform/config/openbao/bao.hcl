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
# outside this box can reach the API over TCP, and nothing inside it can either
# except root, through `docker exec`.
#
# TLS is disabled because the connection never leaves the container's own
# network namespace; a certificate here would protect a loopback hop and cost a
# renewal to forget.
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = "true"
}

# The one route into this API from another container: a unix socket on a bind
# mount that Ingot also mounts, so it can wrap and unwrap object keys under this
# node's region KEK. OpenBao still publishes no port and still joins no Docker
# network, so reaching this socket means being handed the directory it sits in.
#
# Under /openbao/logs because the image's entrypoint chowns that directory to
# the user it then drops to, exactly as it does for the raft path above. A path
# of our own stays root-owned and the server cannot create a socket in it.
# Pinning that user's ids on the host would work too, and would put two numbers
# in this repository that a rebuilt image is free to move: the image allocates
# them implicitly.
#
# All three socket_ options or none. OpenBao's listener applies the mode only
# when the user and the group are set as well, so socket_mode on its own leaves
# the socket at whatever the umask gives. They name the user the server is
# already running as, so the chown is a no-op and the mode is the point: 0600
# means the only thing that can open this socket is that user, or root. Ingot's
# container is root. `ls -l` on the socket after a deploy is what confirms the
# mode took; setting all three is right either way.
#
# A restart replaces the socket file. OpenBao unlinks the path before it binds,
# and Ingot dials per request rather than holding one connection, so neither
# side needs the other to have started first.
listener "unix" {
  address      = "/openbao/logs/api.sock"
  socket_mode  = "0600"
  socket_user  = "openbao"
  socket_group = "openbao"
}

# Auto-unseal against the central OpenBao. The node holds no unseal key and no
# operator types one: the seal key is encrypted under a transit key that only
# central can decrypt with, so revoking this node's token at central means the
# next restart of this container comes back sealed and serving nothing.
#
# Mounts cannot nest, so per-node separation is in the key name rather than a
# sub-path, and the node's policy grants encrypt and decrypt on this key alone.
seal "transit" {
  address    = "https://ssm.latest.dev.fil-forge.com"
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
