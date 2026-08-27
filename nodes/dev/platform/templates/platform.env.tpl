# Secret environment for the platform compose project.
#
# Rendered by scripts/host/deploy-platform.sh from the node's own OpenBao into
# /run/filone/secrets/platform.env, 0400 root, on a tmpfs. Never written to a
# disk that survives a reboot and never committed with values in it.
#
# Only the placeholders below are substituted, and a name with no value in the
# environment is an error rather than an empty string.

# The seal token is not here. It goes into openbao.env next door, written
# straight from /etc/filone/seal-token, because OpenBao needs it before OpenBao
# can answer and everything in this file is read out of OpenBao.

# Postgres. The admin role initialises the cluster; postgres-init creates one
# role and database per service. INGOT_POSTGRES_PASSWORD also has to match the
# DSN rendered into Ingot's YAML in the apps project.
POSTGRES_ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD}
PIRI_POSTGRES_PASSWORD=${PIRI_POSTGRES_PASSWORD}
INGOT_POSTGRES_PASSWORD=${INGOT_POSTGRES_PASSWORD}


# Push-only credential for Grafana Cloud. Shared by the logs and metrics
# endpoints, each of which has its own user id in node.env.
GRAFANA_PUSH_TOKEN=${GRAFANA_PUSH_TOKEN}
