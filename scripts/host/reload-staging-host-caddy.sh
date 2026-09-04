#!/usr/bin/env bash
# Validate and reload the host-owned Caddy configuration for the staging node.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init

[ "${FILONE_HOST_CADDY:-false}" = true ] || exit 0

CADDYFILE=/root/storacha/caddy/Caddyfile
[ -r "$CADDYFILE" ] || die "host Caddyfile is missing: $CADDYFILE"
command -v caddy >/dev/null || die "caddy is not installed on the host"

caddy validate --config "$CADDYFILE" --adapter caddyfile
systemctl reload caddy-guppy
echo "host Caddy validated and caddy-guppy reloaded"
