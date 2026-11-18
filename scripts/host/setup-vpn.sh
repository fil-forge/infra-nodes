#!/usr/bin/env bash
# The node's half of the site-to-site VPN to the database in central's VPC.
#
# Central's half, and what it asks of the site, are in fil-forge/infra-central:
# docs/pandora-vpn.md and docs/decisions/2026-10-compat-server-database.md.
# This follows them: strongSwan with IKEv2, both tunnels up, route-based with
# one xfrm interface per tunnel, only the VPC's CIDR routed into them, the
# site's private /32 on a dummy interface with the database traffic
# source-NATed to it, a clamped TCP MSS, loose reverse-path filtering on the
# tunnels, and a health check that moves the route between them.
#
#   setup-vpn.sh            provision: check, write the configuration, apply it
#   setup-vpn.sh up         recreate the interfaces, addresses, route and
#                           nftables table from /etc/fil-one/vpn.conf; run at
#                           boot by filone-vpn.service
#   setup-vpn.sh health     probe both tunnels and move the route off one that
#                           is down; run by filone-vpn-health.timer
#   setup-vpn.sh status     print the tunnels' state for an operator
#
# Provisioning runs as root from the node's checkout, by hand, and again
# whenever a value changes. Every site-specific value is a provisioning-time
# input, read from the environment, because this repository is public:
#
#   VPN_SITE_PUBLIC_ADDRESS     the site's static public IPv4 address, which
#                               central's customer gateway names; also the IKE
#                               identity
#   VPN_BEHIND_NAT              true when that address is translated in front of
#                               the host, false when it sits on the host
#   VPN_SITE_PRIVATE_ADDRESS    the site's private /32, from central's site list
#   VPN_VPC_CIDR                the VPC side of the tunnel, the only network
#                               routed into it
#   VPN_TUNNEL{1,2}_OUTSIDE_ADDRESS   AWS's two tunnel addresses
#   VPN_TUNNEL{1,2}_INSIDE_LOCAL      this side's tunnel inside address, with
#                                     its prefix (address/30)
#   VPN_TUNNEL{1,2}_INSIDE_REMOTE     AWS's tunnel inside address
#   VPN_PSK_SOURCE              files or openbao
#   VPN_TUNNEL{1,2}_PSK_FILE    with files: a root-only file holding the key
#
# and optionally:
#
#   VPN_TUNNEL_MTU              default 1446, or 1438 behind NAT, the values
#                               central's runbook gives for a 1,500-byte path
#   VPN_DOCKER_NETWORKS         Docker networks whose containers may use the
#                               tunnel, space-separated; default filone
#   VPN_HEALTH_PING             true (default) or false; see "health" below
#
# With openbao, the keys are read from the node's OpenBao at
# filone/vpn#tunnel1_psk and #tunnel2_psk. The keys are never taken from an
# argument, never printed, and written only into the root-only (0600) file
# strongSwan reads them from, /etc/swanctl/conf.d/filone-vpn-secrets.conf.
#
# Section 1 checks every input and the host and changes nothing; a failed check
# stops the run and names itself. A second run with the same inputs changes
# nothing. A changed configuration restarts strongSwan, which takes both
# tunnels down for a few seconds.
#
# The firewall: UFW admits UDP 500 and 4500 and ESP from the two tunnel
# addresses and nothing else. The rules for addresses a previous run admitted
# and this one does not are removed. No other rule is touched.
#
# Container traffic. The nftables table filone_vpn lets forwarded traffic into
# the tunnels only from the subnets of VPN_DOCKER_NETWORKS and only to the VPC,
# and source-NATs it to the site's /32 in a NAT chain that runs before Docker's
# masquerade, so a connection that matched it is not masqueraded again. The
# table is the node's own: Docker and UFW never flush it, and nothing is added
# to or reordered in their chains. Host processes use the /32 through the
# route's source address.
#
# Files under /etc and /run are read only through cat and cmp and written only
# through install and rm, which is what lets the test in tests/ run it against
# stubs.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

CHECKOUT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"

VPN_CONF=/etc/fil-one/vpn.conf
SWANCTL_CONF=/etc/swanctl/conf.d/filone-vpn.conf
SWANCTL_SECRETS=/etc/swanctl/conf.d/filone-vpn-secrets.conf
CHARON_CONF=/etc/strongswan.d/zz-filone-vpn.conf
NFT_RULESET=/run/fil-one/vpn-nftables.conf
NFT_TABLE=filone_vpn
STRONGSWAN_UNIT=strongswan.service
BOOT_UNIT=filone-vpn.service
HEALTH_TIMER=filone-vpn-health.timer
SITE_LINK=filone-site
# A route that loses to the tunnel's and remains when the tunnel's is gone, so
# database traffic is refused rather than sent out the default route in clear.
FALLBACK_METRIC=4294967295
# The keys the configuration file holds, in the order it is written.
CONF_KEYS="VPN_SITE_PUBLIC_ADDRESS VPN_BEHIND_NAT VPN_SITE_PRIVATE_ADDRESS VPN_VPC_CIDR
VPN_TUNNEL1_OUTSIDE_ADDRESS VPN_TUNNEL1_INSIDE_LOCAL VPN_TUNNEL1_INSIDE_REMOTE
VPN_TUNNEL2_OUTSIDE_ADDRESS VPN_TUNNEL2_INSIDE_LOCAL VPN_TUNNEL2_INSIDE_REMOTE
VPN_TUNNEL_MTU VPN_CLIENT_SOURCES VPN_HEALTH_PING"

# The proposals central pins on both tunnels.
IKE_PROPOSALS=aes256gcm16-prfsha384-ecp384-ecp521
ESP_PROPOSALS=aes256gcm16-ecp384-ecp521

fail() { die "check '$1' failed: $2"; }

tunnel_link() { echo "filone-tun$1"; }

# --- Addresses -------------------------------------------------------------
# As in bootstrap-prod-us-east-2.sh.

ipv4_to_int() { # prints the address as a number, or fails
  local IFS=. a b c d octet
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -r a b c d <<<"$1"
  for octet in "$a" "$b" "$c" "$d"; do
    [ "$((10#$octet))" -le 255 ] || return 1
  done
  echo $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

is_cidr() { # an address/prefix whose host bits may be set
  local prefix="${1#*/}"
  [ "$1" != "$prefix" ] && [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$prefix" -le 32 ] &&
    ipv4_to_int "${1%/*}" >/dev/null
}

in_network() { # in_network <address> <address[/prefix]>
  local address network prefix=32 mask
  address="$(ipv4_to_int "$1")" || return 1
  case "$2" in */*) prefix="${2#*/}" ;; esac
  [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
  [ "$prefix" -le 32 ] || return 1
  network="$(ipv4_to_int "${2%/*}")" || return 1
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  [ $((address & mask)) -eq $((network & mask)) ]
}

is_network() { # an address/prefix with no host bits set
  local address prefix="${1#*/}" mask
  is_cidr "$1" || return 1
  address="$(ipv4_to_int "${1%/*}")"
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  [ $((address & mask)) -eq "$address" ]
}

is_private() { # RFC 1918
  in_network "$1" 10.0.0.0/8 || in_network "$1" 172.16.0.0/12 || in_network "$1" 192.168.0.0/16
}

# --- Files -----------------------------------------------------------------

# Install stdin at a path with a mode, unless the path already holds exactly
# that. Says so when it writes, and returns 1 when it did not. The temporary
# copy sits in TMPDIR or, when that is unset, the root-only secrets tmpfs, so a
# key never lands on a disk on its way.
install_if_changed() { # install_if_changed <mode> <destination>
  local mode="$1" destination="$2" tmp
  tmp="$(umask 077 && mktemp "${TMPDIR:-$FILONE_SECRETS_DIR}/.vpn.XXXXXX")" || die "mktemp failed"
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    die "could not write $tmp"
  fi
  if cmp -s "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi
  if ! install -m "$mode" -o root -g root "$tmp" "$destination"; then
    rm -f "$tmp"
    die "could not write $destination"
  fi
  rm -f "$tmp"
  echo "  wrote $destination"
}

# Read /etc/fil-one/vpn.conf into the environment. Parsed, not sourced: only
# the keys above, and only values made of address characters.
load_conf() {
  local content line key value
  content="$(cat "$VPN_CONF" 2>/dev/null)" ||
    die "no $VPN_CONF; this node has no VPN, or scripts/host/setup-vpn.sh has not run"
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    grep -qxF "$key" <<<"$(tr ' ' '\n' <<<"$CONF_KEYS")" || die "$VPN_CONF: unknown key '$key'"
    case "$value" in *[!0-9a-z./\ ]*) die "$VPN_CONF: unexpected value for $key" ;; esac
    printf -v "$key" '%s' "$value"
  done <<<"$content"
  for key in $CONF_KEYS; do
    [ -n "${!key:-}" ] || die "$VPN_CONF has no $key; run scripts/host/setup-vpn.sh again"
  done
}

# --- Network state ---------------------------------------------------------

# Which tunnel the VPC route points at: 1, 2, or nothing.
route_tunnel() {
  ip -4 route show exact "$VPN_VPC_CIDR" | awk -v site="$VPN_SITE_PRIVATE_ADDRESS" '
    $1 == "unreachable" { next }
    {
      dev = ""; src = ""
      for (i = 1; i < NF; i++) { if ($i == "dev") dev = $(i + 1); if ($i == "src") src = $(i + 1) }
      if (src == site && dev ~ /^filone-tun[12]$/) { print substr(dev, length(dev)); exit }
    }'
}

move_route() { # move_route <tunnel>
  ip route replace "$VPN_VPC_CIDR" dev "$(tunnel_link "$1")" src "$VPN_SITE_PRIVATE_ADDRESS" ||
    die "could not route $VPN_VPC_CIDR into tunnel $1"
}

# Whether tunnel n's IKE SA is established with its CHILD_SA installed.
sa_up() {
  local sas
  sas="$(swanctl --list-sas --ike "tunnel$1" 2>/dev/null)" || return 1
  grep -q "^tunnel$1: .*ESTABLISHED" <<<"$sas" && grep -q "^  tunnel$1: .*INSTALLED" <<<"$sas"
}

# Whether AWS's inside address answers through tunnel n. The inside /30 is the
# xfrm interface's own connected route, so this tests that tunnel whichever one
# the VPC route points at.
probe_answers() {
  local remote="VPN_TUNNEL$1_INSIDE_REMOTE"
  ping -n -q -c 3 -W 2 -I "$(tunnel_link "$1")" "${!remote}" >/dev/null 2>&1
}

tunnel_healthy() {
  sa_up "$1" || return 1
  [ "$VPN_HEALTH_PING" = false ] || probe_answers "$1"
}

# --- up: the host network, from vpn.conf -----------------------------------

nft_ruleset() {
  local tunnels mss=$((VPN_TUNNEL_MTU - 40))
  tunnels="{ \"$(tunnel_link 1)\", \"$(tunnel_link 2)\" }"
  cat <<NFT
# Written by scripts/host/setup-vpn.sh. Replaced whole on every change.
table ip $NFT_TABLE
delete table ip $NFT_TABLE
table ip $NFT_TABLE {
  set clients {
    type ipv4_addr
    flags interval
    elements = { ${VPN_CLIENT_SOURCES// /, } }
  }

  # Ahead of Docker's and UFW's filter chains. A drop here is final; an accept
  # still passes through theirs.
  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    iifname $tunnels tcp flags syn / syn,rst tcp option maxseg size > $mss tcp option maxseg size set $mss
    oifname $tunnels tcp flags syn / syn,rst tcp option maxseg size > $mss tcp option maxseg size set $mss
    iifname $tunnels ct state established,related accept
    iifname $tunnels drop
    oifname $tunnels ip daddr != $VPN_VPC_CIDR drop
    oifname $tunnels ip saddr != @clients drop
  }

  # Nothing in the VPC opens a connection to the node.
  chain input {
    type filter hook input priority filter - 10; policy accept;
    iifname $tunnels ct state established,related accept
    iifname $tunnels drop
  }

  # Before Docker's masquerade at srcnat. The first NAT chain that maps a
  # connection decides its source; later ones leave it alone.
  chain postrouting {
    type nat hook postrouting priority srcnat - 10; policy accept;
    oifname $tunnels ip daddr $VPN_VPC_CIDR ip saddr != $VPN_SITE_PRIVATE_ADDRESS snat to $VPN_SITE_PRIVATE_ADDRESS
  }
}
NFT
}

ensure_xfrm_link() { # ensure_xfrm_link <tunnel> <uplink>
  local n="$1" uplink="$2" link details local_var
  link="$(tunnel_link "$n")"
  local_var="VPN_TUNNEL${n}_INSIDE_LOCAL"
  details="$(ip -d -o link show dev "$link" 2>/dev/null || true)"
  if [ -n "$details" ] && ! grep -q "xfrm if_id 0x$n " <<<"$details "; then
    echo "  replacing $link, which is not the xfrm interface for if_id $n"
    ip link del dev "$link" || die "could not remove $link"
    details=""
  fi
  if [ -z "$details" ]; then
    echo "  creating $link"
    ip link add "$link" type xfrm dev "$uplink" if_id "$n" || die "could not create $link"
    details="$(ip -d -o link show dev "$link")"
  fi
  if ! grep -q " mtu $VPN_TUNNEL_MTU " <<<"$details" || ! grep -q "[<,]UP[,>]" <<<"$details"; then
    echo "  setting $link mtu $VPN_TUNNEL_MTU, up"
    ip link set dev "$link" mtu "$VPN_TUNNEL_MTU" up || die "could not bring up $link"
  fi
  ensure_address "$link" "${!local_var}"
  if [ "$(sysctl -n "net.ipv4.conf.$link.rp_filter")" != 2 ]; then
    # Loose: AWS answers on whichever tunnel it prefers, which need not be the
    # one the route points at.
    sysctl -q -w "net.ipv4.conf.$link.rp_filter=2" >/dev/null || die "could not set rp_filter on $link"
  fi
}

ensure_address() { # ensure_address <link> <address/prefix>
  local addresses
  addresses="$(ip -4 -o addr show dev "$1" | awk '{ print $4 }')"
  [ "$addresses" != "$2" ] || return 0
  echo "  setting $2 on $1"
  [ -z "$addresses" ] || ip addr flush dev "$1" || die "could not clear the addresses on $1"
  ip addr add "$2" dev "$1" || die "could not put $2 on $1"
}

bring_up() {
  local uplink n ruleset_changed=0 table_present=0
  uplink="$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  [ -n "$uplink" ] || die "no default route, so no uplink for the xfrm interfaces"

  for n in 1 2; do ensure_xfrm_link "$n" "$uplink"; done

  if ! ip -d -o link show dev "$SITE_LINK" 2>/dev/null | grep -q " dummy "; then
    ip link del dev "$SITE_LINK" 2>/dev/null || true
    echo "  creating $SITE_LINK"
    ip link add "$SITE_LINK" type dummy || die "could not create $SITE_LINK"
  fi
  ip -o link show dev "$SITE_LINK" | grep -q "[<,]UP[,>]" ||
    ip link set dev "$SITE_LINK" up || die "could not bring up $SITE_LINK"
  ensure_address "$SITE_LINK" "$VPN_SITE_PRIVATE_ADDRESS/32"

  install -d -m 0700 -o root -g root /run/fil-one
  nft_ruleset | install_if_changed 0600 "$NFT_RULESET" && ruleset_changed=1
  nft list table ip "$NFT_TABLE" >/dev/null 2>&1 && table_present=1
  if [ "$ruleset_changed" = 1 ] || [ "$table_present" = 0 ]; then
    echo "  loading nftables table $NFT_TABLE"
    nft -f "$NFT_RULESET" || die "nft refused $NFT_RULESET"
  fi

  if ! ip -4 route show exact "$VPN_VPC_CIDR" | grep -q "^unreachable .* metric $FALLBACK_METRIC"; then
    ip route replace unreachable "$VPN_VPC_CIDR" metric "$FALLBACK_METRIC" ||
      die "could not add the fallback route for $VPN_VPC_CIDR"
  fi
  # A route already in a tunnel stays where the health check put it.
  if [ -z "$(route_tunnel)" ]; then
    echo "  routing $VPN_VPC_CIDR into tunnel 1"
    move_route 1
  fi
}

# --- health and status -----------------------------------------------------

health() {
  local active other
  active="$(route_tunnel)"
  [ -n "$active" ] || { move_route 1; active=1; echo "the VPC route was missing; put it in tunnel 1"; }
  other=$((3 - active))
  if tunnel_healthy "$active"; then
    return 0
  fi
  if tunnel_healthy "$other"; then
    move_route "$other"
    echo "tunnel $active is down; moved the database route to tunnel $other"
    return 0
  fi
  echo "both tunnels are down; the database route stays in tunnel $active" >&2
  return 1
}

status() {
  local n active link sa probe outside status=0
  active="$(route_tunnel)"
  echo "VPN to $VPN_VPC_CIDR from $VPN_SITE_PRIVATE_ADDRESS (identity $VPN_SITE_PUBLIC_ADDRESS)"
  for n in 1 2; do
    link="$(tunnel_link "$n")"
    outside="VPN_TUNNEL${n}_OUTSIDE_ADDRESS"
    if sa_up "$n"; then sa="established"; else sa="down"; fi
    if [ "$VPN_HEALTH_PING" = false ]; then
      probe="not probed"
    elif probe_answers "$n"; then
      probe="inside address answers"
    else
      probe="inside address does not answer"
    fi
    printf '  tunnel %s  %-15s %-11s %s, %s%s\n' "$n" "${!outside}" "$link" "$sa" "$probe" \
      "$([ "$active" = "$n" ] && echo ", carries the route")"
  done
  if [ -z "$active" ]; then
    echo "  no tunnel carries the route to $VPN_VPC_CIDR"
    status=1
  elif ! tunnel_healthy "$active"; then
    echo "  the tunnel carrying the route is down"
    status=1
  fi
  if nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
    echo "  nftables table $NFT_TABLE loaded; clients: $VPN_CLIENT_SOURCES"
  else
    echo "  nftables table $NFT_TABLE is missing: no source NAT, no MSS clamp"
    status=1
  fi
  echo "  health check: $(systemctl is-active "$HEALTH_TIMER" 2>/dev/null || true)"
  return "$status"
}

case "${1:-}" in
  up | health | status)
    [ "$(id -u)" -eq 0 ] || die "must run as root"
    load_conf
    case "$1" in
      up) bring_up ;;
      health) health ;;
      status) status ;;
    esac
    exit
    ;;
  "") ;;
  -h | --help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) die "unknown command '$1'; expected up, health, status or nothing" ;;
esac

# --- 1. Verify, changing nothing -------------------------------------------

[ "$(id -u)" -eq 0 ] || fail root "must run as root"

require_address() { # require_address <name>
  [ -n "${!1:-}" ] || fail inputs "set $1"
  ipv4_to_int "${!1}" >/dev/null || fail inputs "$1 is '${!1}', not an IPv4 address"
}

for name in VPN_SITE_PUBLIC_ADDRESS VPN_SITE_PRIVATE_ADDRESS VPN_TUNNEL1_OUTSIDE_ADDRESS \
  VPN_TUNNEL2_OUTSIDE_ADDRESS VPN_TUNNEL1_INSIDE_REMOTE VPN_TUNNEL2_INSIDE_REMOTE; do
  # The site's private address may come as central lists it, with its /32.
  [ "$name" != VPN_SITE_PRIVATE_ADDRESS ] || VPN_SITE_PRIVATE_ADDRESS="${VPN_SITE_PRIVATE_ADDRESS%/32}"
  require_address "$name"
done
for name in VPN_VPC_CIDR VPN_TUNNEL1_INSIDE_LOCAL VPN_TUNNEL2_INSIDE_LOCAL; do
  [ -n "${!name:-}" ] || fail inputs "set $name"
  is_cidr "${!name}" || fail inputs "$name is '${!name}', not an IPv4 address with a prefix"
done

case "${VPN_BEHIND_NAT:-}" in
  true | false) ;;
  "") fail inputs "set VPN_BEHIND_NAT to true when the public address is translated in front of this host, false when it is on the host" ;;
  *) fail inputs "VPN_BEHIND_NAT is '$VPN_BEHIND_NAT'; it must be true or false" ;;
esac
case "${VPN_HEALTH_PING:=true}" in
  true | false) ;;
  *) fail inputs "VPN_HEALTH_PING is '$VPN_HEALTH_PING'; it must be true or false" ;;
esac
if [ -z "${VPN_TUNNEL_MTU:-}" ]; then
  VPN_TUNNEL_MTU=1446
  [ "$VPN_BEHIND_NAT" = false ] || VPN_TUNNEL_MTU=1438
fi
{ [[ "$VPN_TUNNEL_MTU" =~ ^[0-9]{3,4}$ ]] && [ "$VPN_TUNNEL_MTU" -ge 1280 ] && [ "$VPN_TUNNEL_MTU" -le 1446 ]; } ||
  fail inputs "VPN_TUNNEL_MTU is '$VPN_TUNNEL_MTU'; it must be between 1280 and 1446"

[ "${VPN_VPC_CIDR#*/}" -ge 8 ] || fail inputs "VPN_VPC_CIDR $VPN_VPC_CIDR is wider than a /8"
{ is_network "$VPN_VPC_CIDR" && is_private "${VPN_VPC_CIDR%/*}"; } ||
  fail inputs "VPN_VPC_CIDR $VPN_VPC_CIDR is not a private network address with its host bits clear"
is_private "$VPN_SITE_PRIVATE_ADDRESS" ||
  fail inputs "VPN_SITE_PRIVATE_ADDRESS $VPN_SITE_PRIVATE_ADDRESS is not a private address"
! in_network "$VPN_SITE_PRIVATE_ADDRESS" "$VPN_VPC_CIDR" ||
  fail inputs "VPN_SITE_PRIVATE_ADDRESS $VPN_SITE_PRIVATE_ADDRESS is inside VPN_VPC_CIDR $VPN_VPC_CIDR"
[ "$VPN_TUNNEL1_OUTSIDE_ADDRESS" != "$VPN_TUNNEL2_OUTSIDE_ADDRESS" ] ||
  fail inputs "the two tunnel outside addresses are the same"
for n in 1 2; do
  local_var="VPN_TUNNEL${n}_INSIDE_LOCAL"
  remote_var="VPN_TUNNEL${n}_INSIDE_REMOTE"
  in_network "${!remote_var}" "${!local_var}" && [ "${!remote_var}" != "${!local_var%/*}" ] ||
    fail inputs "$remote_var ${!remote_var} is not another address in $local_var ${!local_var}"
done

# The keys. Read into the environment of this run only, and checked without
# printing them: a message names the file or path, never the value.
case "${VPN_PSK_SOURCE:-}" in
  files)
    for n in 1 2; do
      file_var="VPN_TUNNEL${n}_PSK_FILE"
      [ -n "${!file_var:-}" ] || fail "pre-shared keys" "set $file_var to the file holding tunnel $n's key"
      value="$(cat "${!file_var}" 2>/dev/null)" ||
        fail "pre-shared keys" "cannot read ${!file_var}"
      printf -v "PSK$n" '%s' "$value"
    done
    ;;
  openbao)
    filone_init
    for n in 1 2; do
      value="$(bao_get vpn "tunnel${n}_psk")" || fail "pre-shared keys" "cannot read $FILONE_BAO_MOUNT/vpn#tunnel${n}_psk"
      printf -v "PSK$n" '%s' "$value"
    done
    ;;
  "") fail inputs "set VPN_PSK_SOURCE to files or openbao" ;;
  *) fail inputs "VPN_PSK_SOURCE is '$VPN_PSK_SOURCE'; it must be files or openbao" ;;
esac
unset value
for n in 1 2; do
  psk_var="PSK$n"
  [ -n "${!psk_var}" ] || fail "pre-shared keys" "tunnel $n's key is empty"
  [[ "${!psk_var}" =~ ^[[:graph:]]+$ ]] ||
    fail "pre-shared keys" "tunnel $n's key holds whitespace or control characters"
done
[ "$PSK1" != "$PSK2" ] || fail "pre-shared keys" "the two tunnels have the same key"

for tool in swanctl ip nft ufw sysctl ping docker base64; do
  command -v "$tool" >/dev/null || fail tools "$tool is not installed"
done
[ "$(systemctl show -p LoadState --value "$STRONGSWAN_UNIT" 2>/dev/null)" = loaded ] ||
  fail strongswan "$STRONGSWAN_UNIT is not installed. Install charon-systemd and strongswan-swanctl,
       and on Debian 12 or Ubuntu 24.04 also libstrongswan-standard-plugins, for AES-GCM and
       DH groups 20 and 21"
! systemctl is-active --quiet strongswan-starter.service ||
  fail strongswan "strongswan-starter.service, the legacy ipsec.conf daemon, is running and would
       compete for the tunnels. Stop and disable it"

ufw_status="$(ufw status verbose)" || fail ufw "could not read ufw status"
grep -qx 'Status: active' <<<"$ufw_status" || fail ufw "ufw is not active"
grep -q '^Default: .*allow (outgoing)' <<<"$ufw_status" ||
  fail ufw "ufw does not allow outgoing traffic by default, and this script adds only inbound rules"

[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] ||
  fail forwarding "net.ipv4.ip_forward is off, so no container can reach the tunnel. Docker turns it on when it starts"

host_addresses="$(ip -4 -o addr show | awk '{ print $4 }')"
on_host=0
grep -q "^$VPN_SITE_PUBLIC_ADDRESS/" <<<"$host_addresses" && on_host=1
if [ "$VPN_BEHIND_NAT" = false ] && [ "$on_host" = 0 ]; then
  fail "public address" "VPN_BEHIND_NAT is false but $VPN_SITE_PUBLIC_ADDRESS is not on this host"
elif [ "$VPN_BEHIND_NAT" = true ] && [ "$on_host" = 1 ]; then
  fail "public address" "VPN_BEHIND_NAT is true but $VPN_SITE_PUBLIC_ADDRESS is on this host"
fi

# Nothing else may route the VPC, and no address on the host may sit inside it.
existing_route="$(ip -4 route show exact "$VPN_VPC_CIDR" | grep -v '^unreachable ' |
  grep -v ' dev filone-tun[12] ' || true)"
[ -z "$existing_route" ] ||
  fail routes "something else routes $VPN_VPC_CIDR: $existing_route"
while read -r address; do
  [ -n "$address" ] || continue
  case "$address" in "$VPN_SITE_PRIVATE_ADDRESS/32") continue ;; esac
  ! in_network "${address%/*}" "$VPN_VPC_CIDR" ||
    fail routes "$address on this host is inside $VPN_VPC_CIDR"
done <<<"$host_addresses"

# The container subnets allowed into the tunnel, from Docker.
VPN_CLIENT_SOURCES=""
for network in ${VPN_DOCKER_NETWORKS:-filone}; do
  subnets="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$network" 2>/dev/null)" ||
    fail "docker networks" "there is no Docker network '$network'"
  for subnet in $subnets; do
    is_cidr "$subnet" || continue # an IPv6 subnet
    ! in_network "${subnet%/*}" "$VPN_VPC_CIDR" ||
      fail "docker networks" "network '$network' uses $subnet, which overlaps $VPN_VPC_CIDR"
    VPN_CLIENT_SOURCES="${VPN_CLIENT_SOURCES:+$VPN_CLIENT_SOURCES }$subnet"
  done
done
[ -n "$VPN_CLIENT_SOURCES" ] || fail "docker networks" "no IPv4 subnet on ${VPN_DOCKER_NETWORKS:-filone}"

# The outside addresses a previous run admitted, whose rules go if they changed.
previous_outside=""
if previous="$(cat "$VPN_CONF" 2>/dev/null)"; then
  previous_outside="$(sed -n 's/^VPN_TUNNEL[12]_OUTSIDE_ADDRESS=//p' <<<"$previous")"
fi

# --- 2. Configuration files ------------------------------------------------

changed=0
install -d -m 0755 /etc/fil-one /etc/swanctl/conf.d /etc/strongswan.d
install -d -m 0700 -o root -g root /run/fil-one /run/fil-one/secrets

for key in $CONF_KEYS; do printf '%s=%s\n' "$key" "${!key}"; done |
  install_if_changed 0600 "$VPN_CONF" || true

# Routes come from this script, not from charon: with 0.0.0.0/0 traffic
# selectors, charon's own route would take every packet on the host.
cat <<'CHARON' | install_if_changed 0644 "$CHARON_CONF" && changed=1
# Written by scripts/host/setup-vpn.sh.
charon {
  install_routes = no
}
CHARON

swanctl_connections() {
  local n outside local_addrs=""
  # On the host the address can be pinned; behind NAT the host's own address is
  # a private one strongSwan finds itself.
  [ "$VPN_BEHIND_NAT" = true ] || local_addrs="    local_addrs = $VPN_SITE_PUBLIC_ADDRESS"
  echo "# Written by scripts/host/setup-vpn.sh."
  echo "connections {"
  for n in 1 2; do
    outside="VPN_TUNNEL${n}_OUTSIDE_ADDRESS"
    cat <<EOF
  tunnel$n {
    version = 2
$local_addrs
    remote_addrs = ${!outside}
    proposals = $IKE_PROPOSALS
    keyingtries = 0
    mobike = no
    dpd_delay = 10s
    local {
      auth = psk
      id = $VPN_SITE_PUBLIC_ADDRESS
    }
    remote {
      auth = psk
      id = ${!outside}
    }
    children {
      tunnel$n {
        local_ts = 0.0.0.0/0
        remote_ts = 0.0.0.0/0
        esp_proposals = $ESP_PROPOSALS
        if_id_in = $n
        if_id_out = $n
        start_action = start
        dpd_action = restart
        close_action = start
      }
    }
  }
EOF
  done
  echo "}"
}

swanctl_secrets() {
  local n outside psk
  echo "# Written by scripts/host/setup-vpn.sh."
  echo "secrets {"
  for n in 1 2; do
    outside="VPN_TUNNEL${n}_OUTSIDE_ADDRESS"
    psk="PSK$n"
    cat <<EOF
  ike-tunnel$n {
    id-1 = $VPN_SITE_PUBLIC_ADDRESS
    id-2 = ${!outside}
    secret = 0s$(printf '%s' "${!psk}" | base64 | tr -d '\n')
  }
EOF
  done
  echo "}"
}

swanctl_connections | install_if_changed 0600 "$SWANCTL_CONF" && changed=1
swanctl_secrets | install_if_changed 0600 "$SWANCTL_SECRETS" && changed=1
unset PSK1 PSK2

# --- 3. Firewall -----------------------------------------------------------

# ufw skips a rule it already has, and says so.
ufw_rule() { # ufw_rule allow|delete <rule words...>
  local verb="$1" output
  shift
  if [ "$verb" = allow ]; then
    output="$(ufw allow "$@")" || die "ufw refused: allow $*"
    grep -q '^Skipping' <<<"$output" || echo "  ufw allow $*"
  else
    output="$(ufw delete allow "$@" 2>&1)" || true
    grep -q 'non-existent' <<<"$output" || echo "  ufw delete allow $*"
  fi
}

for old in $previous_outside; do
  [ "$old" != "$VPN_TUNNEL1_OUTSIDE_ADDRESS" ] && [ "$old" != "$VPN_TUNNEL2_OUTSIDE_ADDRESS" ] ||
    continue
  ufw_rule delete proto udp from "$old" to any port 500,4500
  ufw_rule delete proto esp from "$old" to any
done
for n in 1 2; do
  outside="VPN_TUNNEL${n}_OUTSIDE_ADDRESS"
  ufw_rule allow proto udp from "${!outside}" to any port 500,4500 comment "filone-vpn tunnel $n"
  ufw_rule allow proto esp from "${!outside}" to any comment "filone-vpn tunnel $n"
done

# --- 4. Host network -------------------------------------------------------

bring_up

# --- 5. Units and strongSwan -----------------------------------------------

FILONE_CHECKOUT="$CHECKOUT"
sync_systemd_units

if [ "$changed" = 1 ] || ! systemctl is-active --quiet "$STRONGSWAN_UNIT"; then
  echo "  restarting $STRONGSWAN_UNIT"
  systemctl is-enabled --quiet "$STRONGSWAN_UNIT" || systemctl enable "$STRONGSWAN_UNIT" >/dev/null
  systemctl restart "$STRONGSWAN_UNIT" || die "$STRONGSWAN_UNIT did not start"
fi

# charon answers on its vici socket once it is up; then it must offer what
# central pins, which only the openssl and gcm plugins provide.
algorithms=""
for _ in $(seq 1 20); do
  algorithms="$(swanctl --list-algs 2>/dev/null)" && break
  sleep 0.5
done
[ -n "$algorithms" ] || die "charon did not answer on its vici socket"
for algorithm in AES_GCM_16 PRF_HMAC_SHA2_384 ECP_384 ECP_521; do
  grep -q "$algorithm\[" <<<"$algorithms" ||
    die "charon offers no $algorithm. Install libstrongswan-standard-plugins (Debian 12, Ubuntu 24.04)"
done
swanctl --list-conns | grep -q '^tunnel2: ' ||
  die "charon did not load $SWANCTL_CONF; 'journalctl -u $STRONGSWAN_UNIT' says why"

for unit in "$BOOT_UNIT" "$HEALTH_TIMER"; do
  systemctl is-enabled --quiet "$unit" || {
    echo "  enabling $unit"
    systemctl enable --now "$unit" >/dev/null || die "could not enable $unit"
  }
done

echo "VPN provisioned. The tunnels come up as AWS answers; check them with:"
echo "  scripts/host/setup-vpn.sh status"
