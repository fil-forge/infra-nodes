# Non-secret configuration for the dev node. Every secret this node holds lives
# in the OpenBao on the node itself and none of it passes through OpenTofu, so
# this file is safe to commit — and the root is unusable without it.

# Both EBS volumes live here too, and neither can move, so changing this means
# building a new node rather than moving this one.
availability_zone = "us-east-2a"

# The Piris answer at piri-<n>.us-east-9.latest.dev.fil-forge.com and Ingot at
# s3.us-east-9.latest.dev.filonecontent.com, the names RFC 16 gives Forge
# services. `latest` is this long-lived dev environment's label; staging uses
# `staging` and production carries none, so the suffixes are stated here rather
# than composed from a stage.
hostname_suffix       = "latest.dev.fil-forge.com"
ingot_hostname_suffix = "latest.dev.filonecontent.com"

# One Piri per storage volume, as production runs them. Must match the Piri
# services in nodes/dev/apps/compose.yml.
piri_count = 3

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

# Ingot's spool. Piri's blobs lived here too before each Piri got a volume of
# its own, and an EBS volume cannot shrink, so it keeps its size.
data_volume_size = 500

# Each Piri's blobs. These are the volumes that grow.
piri_volume_size = 100
