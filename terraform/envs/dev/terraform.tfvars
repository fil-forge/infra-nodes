# Non-secret configuration for the dev node. Every secret this node holds lives
# in the OpenBao on the node itself and none of it passes through OpenTofu, so
# this file is safe to commit — and the root is unusable without it.

# Both EBS volumes live here too, and neither can move, so changing this means
# building a new node rather than moving this one.
availability_zone = "us-east-2a"

# Piri answers at piri.dev.forge-sandbox.fil.one, Ingot at
# ingot.dev.forge-sandbox.fil.one. The stage label lives inside the zone, which
# is what lets one delegation serve dev and any later stage.
hostname_suffix = "dev.forge-sandbox.fil.one"

# The virtual S3 region this node presents. Deliberately not a real AWS region:
# an S3 client that guesses a real one should fail loudly rather than half-work.
# Must match Ingot's config, hilt's `provider add`, and clients' AWS_REGION.
region_label = "us-east-9"

# 2 vCPU / 8 GB on Graviton, in unlimited credit mode. Burstable is acceptable
# because the node's steady load is low and its peaks are short; unlimited is
# not optional, because a throttled node misses proofs.
instance_type = "t4g.large"

# Postgres, the OpenBao raft store, Caddy's certificates, rendered state. Small
# and slow-growing; this is the volume that carries the node's identity.
control_volume_size = 50

# Piri's blobs and Ingot's spool. This is the one that grows.
data_volume_size = 500
