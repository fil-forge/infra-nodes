# Staging runs as a bare-metal appliance

Staging runs on the Servers.com host at `23.83.66.244` in `eu-central-3`. The appliance serves
Piri at `piri-0.staging.fil-forge.com` and Ingot at
`s3.eu-central-3.staging.filonecontent.com`.

The host owns Caddy, Lotus, Grafana Alloy and its unrelated workloads. FilOne imports one Caddy
snippet directly from `/root/fil-one/infra-nodes`, validates the combined configuration and reloads
`caddy-guppy`. Piri and Ingot bind only to loopback. Their Docker network uses the fixed
`172.18.0.0/16` subnet. Source-subnet UFW rules permit that network to reach the host's TCP 443
Caddy listener and TCP 1234 Lotus RPC listener without depending on Docker's generated bridge name.
The rules do not permit public access. The host firewall permits public TCP 80 and 443 for Caddy and
ACME. The host Alloy service collects host and container telemetry, including the deploy stamps
under `/mnt/data/fil-one/control/state/metrics`.

The OpenTofu staging root owns only the two Route53 A records. It creates no server, volume, IAM
role or other AWS host resource. Appliance control state and data live in separate directories:
`/mnt/data/fil-one/control` and `/mnt/data/fil-one/data`.

Piri reaches the host's Lotus RPC through `host.docker.internal:1234` without an authorization
token. Staging has no Indexer/IPNI configuration. Indexer and Swarf identities remain registered
centrally and are not appliance dependencies.
