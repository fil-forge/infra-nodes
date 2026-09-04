#!/usr/bin/env bash
# Prepare the existing Servers.com host for the FilOne staging appliance.
#
# This script owns only FilOne paths, units, Docker networking and the one Caddy
# import below. Lotus, Caddy's other sites and unrelated host workloads remain
# under their existing owner.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

CHECKOUT=/root/fil-one/infra-nodes
CADDYFILE=/root/storacha/caddy/Caddyfile
SNIPPET="$CHECKOUT/nodes/staging/platform/config/caddy/host-caddy.caddy"
IMPORT="import $SNIPPET"
FILONE_SUBNET=172.18.0.0/16

[ -d "$CHECKOUT/.git" ] || { echo "ERROR: expected checkout at $CHECKOUT" >&2; exit 1; }
[ -r "$SNIPPET" ] || { echo "ERROR: staging Caddy snippet is missing: $SNIPPET" >&2; exit 1; }
[ -r "$CADDYFILE" ] || { echo "ERROR: host Caddyfile is missing: $CADDYFILE" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker is not installed" >&2; exit 1; }
command -v ufw >/dev/null || { echo "ERROR: ufw is not installed" >&2; exit 1; }

install -d -m 0755 \
  /mnt/data/filone/control/openbao \
  /mnt/data/filone/control/postgres \
  /mnt/data/filone/control/state/metrics \
  /mnt/data/filone/data/piri \
  /mnt/data/filone/data/ingot
install -d -m 0700 /run/filone /run/filone/secrets /run/filone/bao
install -d -m 0755 /etc/filone
cat >/etc/tmpfiles.d/filone.conf <<'TMPFILES'
d /run/filone 0700 root root -
d /run/filone/secrets 0700 root root -
d /run/filone/bao 0700 root root -
TMPFILES

if docker network inspect filone >/dev/null 2>&1; then
  actual_subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' filone)"
  [ "$actual_subnet" = "$FILONE_SUBNET" ] || {
    echo "ERROR: filone network uses $actual_subnet, expected $FILONE_SUBNET" >&2
    exit 1
  }
else
  docker network create --subnet "$FILONE_SUBNET" filone
fi

cat >/etc/filone/node.conf <<'CONF'
FILONE_NODE=staging
FILONE_CHECKOUT=/root/fil-one/infra-nodes
FILONE_GIT_REF=main
FILONE_HOST_CADDY=true
CONF

install -m 0644 "$CHECKOUT"/systemd/filone-*.service "$CHECKOUT"/systemd/filone-*.timer /etc/systemd/system/
systemctl daemon-reload

if ! grep -qxF "$IMPORT" "$CADDYFILE"; then
  printf '\n# FilOne staging appliance. The snippet stays in the checked-out repository.\n%s\n' "$IMPORT" >>"$CADDYFILE"
fi

ufw allow from "$FILONE_SUBNET" to any port 443 proto tcp comment 'FilOne Docker to host Caddy'
ufw allow from "$FILONE_SUBNET" to any port 1234 proto tcp comment 'FilOne Docker to host Lotus RPC'

"$CHECKOUT/scripts/host/reload-host-caddy.sh"
date -Is >/etc/filone/bootstrap-complete
echo "staging bootstrap complete"
