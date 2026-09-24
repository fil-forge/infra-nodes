#!/usr/bin/env bash
# Prepare the bare-metal host for the staging/pilot-mad FilOne appliance.
#
# One host, not every staging node: the checkout path, the state directories and
# the firewall rules below are this machine's. Another bare-metal node gets a
# script of its own rather than a flag on this one.
#
# What cloud-init does on the EC2 node, minus everything EC2: no volume waits,
# no clone of a repository the operator has already checked out, and no secret.
# It brings the box to the point where provision-platform.sh can run.
#
# The host also runs k3s and an IPNI indexer. Nothing here touches either: the
# directories are FilOne's, the Docker network is FilOne's, and the firewall
# rules are added only to a firewall that is already running.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

CHECKOUT=/opt/fil-one/infra-nodes
FILONE_ROOT=/fil-one
FILONE_SUBNET=172.18.0.0/16

[ -d "$CHECKOUT/.git" ] || { echo "ERROR: expected checkout at $CHECKOUT" >&2; exit 1; }

# Docker rather than the host's containerd: k3s runs its own, and the deploy
# scripts drive `docker compose`.
command -v docker >/dev/null || {
  echo "ERROR: docker is not installed. Ubuntu's own packages are what the EC2" >&2
  echo "       node uses: apt-get install -y docker.io docker-compose-v2" >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  echo "ERROR: the docker compose plugin is missing: apt-get install -y docker-compose-v2" >&2
  exit 1
}

echo "[1/6] Creating the state directories under $FILONE_ROOT"
# Control carries the node's identity; data is the one expected to move to its
# own volume later. Both are stated in nodes/staging/pilot-mad/node.env, and
# these paths have to match it.
install -d -m 0755 \
  "$FILONE_ROOT/control/openbao" \
  "$FILONE_ROOT/control/postgres" \
  "$FILONE_ROOT/control/caddy" \
  "$FILONE_ROOT/control/alloy" \
  "$FILONE_ROOT/control/state/metrics" \
  "$FILONE_ROOT/data/piri" \
  "$FILONE_ROOT/data/ingot"

echo "[2/6] Creating the secrets tmpfs"
install -d -m 0700 -o root -g root /run/fil-one /run/fil-one/secrets /run/fil-one/bao
install -d -m 0755 /etc/fil-one
cat >/etc/tmpfiles.d/filone.conf <<'TMPFILES'
d /run/fil-one 0700 root root -
d /run/fil-one/secrets 0700 root root -
d /run/fil-one/bao 0700 root root -
TMPFILES

echo "[3/6] Creating the shared docker network"
# A fixed subnet, because this host has other networking of its own and a
# Docker-assigned range is one more thing to reason about. k3s sits on
# 10.42.0.0/16 and 10.43.0.0/16, so neither this nor docker0 collides with it.
if docker network inspect filone >/dev/null 2>&1; then
  actual_subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' filone)"
  [ "$actual_subnet" = "$FILONE_SUBNET" ] || {
    echo "ERROR: filone network uses $actual_subnet, expected $FILONE_SUBNET" >&2
    exit 1
  }
else
  docker network create --subnet "$FILONE_SUBNET" filone
fi

echo "[4/6] Writing /etc/fil-one/node.conf"
cat >/etc/fil-one/node.conf <<'CONF'
FILONE_NODE=staging/pilot-mad
FILONE_CHECKOUT=/opt/fil-one/infra-nodes
FILONE_GIT_REF=main
CONF

echo "[5/6] Installing systemd units"
install -m 0644 "$CHECKOUT"/systemd/filone-*.service "$CHECKOUT"/systemd/filone-*.timer /etc/systemd/system/
systemctl daemon-reload

echo "[6/6] Opening the firewall for Caddy"
# Caddy is the only listener this node publishes: 80 for ACME challenges and
# redirects, 443 for both public sites.
#
# Rules are added only to a firewall that is already running. Enabling one on a
# host serving other workloads is that host owner's call, not this script's.
if command -v ufw >/dev/null && ufw status | head -1 | grep -q 'Status: active'; then
  ufw allow 80/tcp comment 'FilOne Caddy HTTP and ACME'
  ufw allow 443/tcp comment 'FilOne Caddy HTTPS'
else
  echo "  ufw is not active; make sure TCP 80 and 443 reach this host"
fi

date -Is >/etc/fil-one/bootstrap-complete
echo "staging/pilot-mad bootstrap complete"
