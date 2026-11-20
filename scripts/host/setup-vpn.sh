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
#   setup-vpn.sh down       take the VPN off the node: stop and disable its
#                           units and strongSwan, and remove the interfaces,
#                           routes, nftables table, UFW rules and files that
#                           provisioning made
#
# Provisioning runs as root from the node's checkout, by hand, and again
# whenever a value changes. It installs strongSwan's packages when they are
# missing. Every site-specific value is a provisioning-time input, read from
# the environment, because this repository is public:
#
#   VPN_SITE_PUBLIC_ADDRESS     the site's static public IPv4 address, which
#                               central's customer gateway names; also the IKE
#                               identity
#   VPN_BEHIND_NAT              true when that address is translated in front of
#                               the host, false when it sits on the host
#   VPN_SITE_PRIVATE_ADDRESS    the site's private /32, from central's site list
#   VPN_TUNNEL{1,2}_OUTSIDE_ADDRESS   AWS's two tunnel addresses
#   VPN_TUNNEL{1,2}_INSIDE_LOCAL      this side's inside address of the same
#                                     tunnel, with its prefix (address/30)
#   VPN_TUNNEL{1,2}_INSIDE_REMOTE     AWS's inside address of the same tunnel
#   VPN_PSK_SOURCE              files or openbao; unset keeps the keys already
#                               installed, for a re-run that changes no key
#   VPN_TUNNEL{1,2}_PSK_FILE    with files: a root-only file holding the key
#
# and optionally:
#
#   VPN_VPC_CIDR                the VPC side of the tunnel, the only network
#                               routed into it. Defaults to the one CIDR
#                               central's VPN document states; another value
#                               needs VPN_VPC_CIDR_OVERRIDE=true as well
#   VPN_TUNNEL_MTU              default 1446, or 1438 behind NAT, the values
#                               central's runbook gives for a 1,500-byte path
#   VPN_DOCKER_NETWORKS         Docker networks whose containers may use the
#                               tunnel, space-separated; default filone
#   VPN_HEALTH_PING             true (default) or false; see "health" below
#
# With openbao, the keys are read from the node's OpenBao at
# filone/vpn#tunnel1_psk and #tunnel2_psk. With no VPN_PSK_SOURCE, they are
# read back from the secrets file a previous run wrote, and only while its
# tunnel addresses are still the ones given. The keys are never taken from an
# argument, never printed, and written only into the root-only (0600) file
# strongSwan reads them from, /etc/swanctl/conf.d/filone-vpn-secrets.conf.
#
# Provisioning and down hold the deploy lock, so a reconcile pass cannot reset
# the checkout under them, and the VPN lock, which the health check also takes,
# so a check that read the previous vpn.conf cannot put back a route the run
# removes. A health check that finds the VPN lock held skips its turn.
#
# Section 1 checks every input and the host and changes nothing, apart from
# installing strongSwan's packages once the inputs pass; a failed check stops
# the run and names itself. A second run with the same inputs changes
# nothing. A changed configuration restarts strongSwan, which takes both
# tunnels down for a few seconds; a change to only a file's mode or owner
# rewrites the file without the restart. strongSwan's files are written only
# after the firewall and the host network, next to vpn.conf, and a run that
# changes them first leaves a marker under /run/fil-one that only a restart and
# passing algorithm and connection checks clear, so a re-run after a run that
# stopped on the way always restarts strongSwan.
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
# Files under /etc and /run are read only through cat, cmp and stat and written
# only through install, mv and rm, which is what lets the test in tests/ run it
# against stubs. The two lock files are the exception, and the test moves them
# with FILONE_DEPLOY_LOCK_FILE and VPN_LOCK_FILE.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

CHECKOUT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"

VPN_CONF=/etc/fil-one/vpn.conf
SWANCTL_CONF=/etc/swanctl/conf.d/filone-vpn.conf
SWANCTL_SECRETS=/etc/swanctl/conf.d/filone-vpn-secrets.conf
CHARON_CONF=/etc/strongswan.d/zz-filone-vpn.conf
NFT_RULESET=/run/fil-one/vpn-nftables.conf
STRONGSWAN_FILES="$CHARON_CONF $SWANCTL_CONF $SWANCTL_SECRETS"
# The files a provisioning run writes as one set, vpn.conf last.
STAGED_FILES="$STRONGSWAN_FILES $VPN_CONF"
# Set while strongSwan has yet to be restarted onto a changed configuration. A
# reboot clears it, and strongSwan then loads the files as they stand.
RESTART_PENDING=/run/fil-one/vpn-restart-pending
NFT_TABLE=filone_vpn
STRONGSWAN_UNIT=strongswan.service
BOOT_UNIT=filone-vpn.service
HEALTH_TIMER=filone-vpn-health.timer
HEALTH_UNIT=filone-vpn-health.service
VPN_LOCK_FILE="${VPN_LOCK_FILE:-/run/fil-one/vpn.lock}"
# How long provisioning waits for a health check to finish; the check's unit
# gives it 30 seconds at most.
VPN_LOCK_WAIT=60
SITE_LINK=filone-site
# A route that loses to the tunnel's and remains when the tunnel's is gone, so
# database traffic is refused rather than sent out the default route in clear.
FALLBACK_METRIC=4294967295
# The keys the configuration file holds, in the order it is written.
CONF_KEYS="VPN_SITE_PUBLIC_ADDRESS VPN_BEHIND_NAT VPN_SITE_PRIVATE_ADDRESS VPN_VPC_CIDR
VPN_TUNNEL1_OUTSIDE_ADDRESS VPN_TUNNEL1_INSIDE_LOCAL VPN_TUNNEL1_INSIDE_REMOTE
VPN_TUNNEL2_OUTSIDE_ADDRESS VPN_TUNNEL2_INSIDE_LOCAL VPN_TUNNEL2_INSIDE_REMOTE
VPN_TUNNEL_MTU VPN_CLIENT_SOURCES VPN_HEALTH_PING"

# The VPC's side of the tunnel, as central's docs/pandora-vpn.md states it.
STATED_VPC_CIDR=10.20.192.0/18

# strongSwan's packages. On Debian 12 and Ubuntu 24.04 the openssl and gcm
# plugins, which provide the AES-GCM and DH groups 20 and 21 central pins, are
# in libstrongswan-standard-plugins, a recommended package that an install
# without recommends leaves out, so it is named.
STRONGSWAN_PACKAGES="charon-systemd strongswan-swanctl libstrongswan-standard-plugins"

# The proposals central pins on both tunnels.
IKE_PROPOSALS=aes256gcm16-prfsha384-ecp384-ecp521
ESP_PROPOSALS=aes256gcm16-ecp384-ecp521

fail() { die "check '$1' failed: $2"; }

# Taken before vpn.conf is read and held until the routes match it. wait: give
# up after VPN_LOCK_WAIT seconds; skip: return non-zero at once when held.
take_vpn_lock() { # take_vpn_lock wait|skip
  install -d -m 0700 -o root -g root /run/fil-one
  exec 8>"$VPN_LOCK_FILE"
  if [ "$1" = skip ]; then
    flock -n 8
  else
    flock -w "$VPN_LOCK_WAIT" 8 ||
      die "something has held $VPN_LOCK_FILE for ${VPN_LOCK_WAIT}s; 'fuser -v $VPN_LOCK_FILE' names it"
  fi
}

release_vpn_lock() { exec 8>&-; }

tunnel_link() { echo "filone-tun$1"; }

# --- Addresses -------------------------------------------------------------
# As in bootstrap-prod-us-east-2.sh, except that an octet or prefix with a
# leading zero is refused: nft and strongSwan read an address through
# inet_aton, which takes 010 as octal 8.

ipv4_to_int() { # prints the address as a number, or fails
  local IFS=. a b c d octet
  [[ "$1" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
  read -r a b c d <<<"$1"
  for octet in "$a" "$b" "$c" "$d"; do
    [ "$((10#$octet))" -le 255 ] || return 1
  done
  echo $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

is_cidr() { # an address/prefix whose host bits may be set
  local prefix="${1#*/}"
  [ "$1" != "$prefix" ] && [[ "$prefix" =~ ^(0|[1-9][0-9]?)$ ]] && [ "$prefix" -le 32 ] &&
    ipv4_to_int "${1%/*}" >/dev/null
}

in_network() { # in_network <address> <address[/prefix]>
  local address network prefix=32 mask
  address="$(ipv4_to_int "$1")" || return 1
  case "$2" in */*) prefix="${2#*/}" ;; esac
  [[ "$prefix" =~ ^(0|[1-9][0-9]?)$ ]] || return 1
  [ "$prefix" -le 32 ] || return 1
  network="$(ipv4_to_int "${2%/*}")" || return 1
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  [ $((address & mask)) -eq $((network & mask)) ]
}

# Two prefixes are either nested or apart, so they overlap when either one's
# address lies in the other. Host bits in either are harmless.
overlaps() { # overlaps <address[/prefix]> <address[/prefix]>
  in_network "${1%/*}" "$2" || in_network "${2%/*}" "$1"
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

# Copy stdin to a temporary file, STAGED, and compare it with a path that should
# hold it at a mode, owned by root. FILE_STATE is then same, mode (the contents
# match but the mode or owner does not) or content. The temporary copy sits in
# TMPDIR when that is set, and otherwise in the root-only secrets directory on
# /run's tmpfs, which keeps a key off the disk on its way. Under systemd and
# from a root shell without TMPDIR, it is the latter.
#
# These functions read stdin and set variables, so they are called with a
# redirection, never at the end of a pipeline: there a die would end only the
# pipeline's subshell and the run would go on.
stage_file() { # stage_file <mode> <destination>
  local mode="$1" destination="$2"
  STAGED="$(umask 077 && mktemp "${TMPDIR:-$FILONE_SECRETS_DIR}/.vpn.XXXXXX")" || die "mktemp failed"
  if ! cat >"$STAGED"; then
    rm -f "$STAGED"
    die "could not write $STAGED"
  fi
  if ! cmp -s "$STAGED" "$destination"; then
    FILE_STATE=content
  elif [ "$(stat -c '%a %u %g' "$destination" 2>/dev/null)" != "${mode#0} 0 0" ]; then
    FILE_STATE=mode
  else
    FILE_STATE=same
  fi
}

file_state() { # file_state <mode> <destination>: sets FILE_STATE, writes nothing
  stage_file "$@"
  rm -f "$STAGED"
}

# Install stdin at a path with a mode, unless the path already holds exactly
# that, with that mode and owned by root. Says so when it writes. FILE_STATE
# says what differed; INSTALLED is 1 when it wrote and 0 when it did not.
install_if_changed() { # install_if_changed <mode> <destination>
  INSTALLED=0
  stage_file "$@"
  if [ "$FILE_STATE" != same ]; then
    if ! install -m "$1" -o root -g root "$STAGED" "$2"; then
      rm -f "$STAGED"
      die "could not write $2"
    fi
    INSTALLED=1
    echo "  wrote $2"
  fi
  rm -f "$STAGED"
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

# The route that loses to the tunnel's and refuses VPC traffic when the
# tunnel's is gone.
ensure_fallback_route() {
  ip -4 route show exact "$VPN_VPC_CIDR" | grep -q "^unreachable .* metric $FALLBACK_METRIC" && return 0
  echo "  restoring the fallback route for $VPN_VPC_CIDR"
  ip route replace unreachable "$VPN_VPC_CIDR" metric "$FALLBACK_METRIC" ||
    die "could not add the fallback route for $VPN_VPC_CIDR"
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

# Whether AWS's inside address answers through tunnel n: three pings, of which
# one reply is enough. The inside /30 is the xfrm interface's own connected
# route, so this tests that tunnel whichever one the VPC route points at.
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

  # At boot nothing else may have created the secrets directory yet; the
  # temporary copy of the ruleset goes there.
  install -d -m 0700 -o root -g root /run/fil-one "$FILONE_SECRETS_DIR"
  install_if_changed 0600 "$NFT_RULESET" < <(nft_ruleset)
  ruleset_changed="$INSTALLED"
  nft list table ip "$NFT_TABLE" >/dev/null 2>&1 && table_present=1
  if [ "$ruleset_changed" = 1 ] || [ "$table_present" = 0 ]; then
    echo "  loading nftables table $NFT_TABLE"
    if ! nft -f "$NFT_RULESET"; then
      # Gone, so the next run loads its ruleset again rather than taking the
      # refused one for the table already loaded.
      rm -f "$NFT_RULESET"
      die "nft refused the ruleset; the table loaded before stays as it was"
    fi
  fi

  ensure_fallback_route
  # A route already in a tunnel stays where the health check put it.
  if [ -z "$(route_tunnel)" ]; then
    echo "  routing $VPN_VPC_CIDR into tunnel 1"
    move_route 1
  fi
}

# The routes this script made for any CIDR but the one given, or for every CIDR
# with none: into a tunnel, other than the inside /30s the kernel adds, or
# unreachable at the fallback metric.
remove_vpn_routes() { # remove_vpn_routes [<CIDR to keep>]
  local keep="${1:-}" destination device
  while read -r destination device; do
    [ -n "$destination" ] || continue
    echo "  removing the route to $destination"
    if [ "$device" = unreachable ]; then
      ip route del unreachable "$destination" metric "$FALLBACK_METRIC"
    else
      ip route del "$destination" dev "$device"
    fi || die "could not remove the route to $destination"
  done < <(ip -4 route show | awk -v cidr="$keep" -v metric="$FALLBACK_METRIC" '
    $1 == "unreachable" { if ($2 != cidr && $NF == metric && $(NF - 1) == "metric") print $2, "unreachable"; next }
    $1 == cidr || / proto kernel / { next }
    { for (i = 2; i < NF; i++) if ($i == "dev" && $(i + 1) ~ /^filone-tun[12]$/) { print $1, $(i + 1); next } }')
}

# The <file>.new and <file>.old copies a run that stopped while writing the set
# left behind. One may hold the keys.
remove_staged_copies() {
  local file copy
  for file in $STAGED_FILES; do
    for copy in "$file.new" "$file.old"; do
      cat "$copy" >/dev/null 2>&1 || continue
      rm -f "$copy" || die "could not remove $copy"
      echo "  removed $copy"
    done
  done
}

# The tunnel addresses vpn.conf names, and any other address whose UFW rules
# carry this script's comment. Not every word is an address; callers check.
admitted_addresses() {
  {
    sed -n 's/^VPN_TUNNEL[12]_OUTSIDE_ADDRESS=//p' < <(cat "$VPN_CONF" 2>/dev/null || true)
    ufw status | awk '/# filone-vpn/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; break } }'
  } | sort -u
}

# ufw skips a rule it already has, and says so. A delete of a rule that is
# already gone is fine; any other failure stops the run.
ufw_rule() { # ufw_rule allow|delete <rule words...>
  local verb="$1" output
  shift
  if [ "$verb" = allow ]; then
    output="$(ufw allow "$@")" || die "ufw refused: allow $*"
    grep -q '^Skipping' <<<"$output" || echo "  ufw allow $*"
  else
    output="$(ufw delete allow "$@" 2>&1)" || grep -q 'non-existent' <<<"$output" ||
      die "ufw refused: delete allow $*: $(tr '\n' ' ' <<<"$output")"
    grep -q 'non-existent' <<<"$output" || echo "  ufw delete allow $*"
  fi
}

# --- health and status -----------------------------------------------------

health() {
  local active other
  ensure_fallback_route
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

# One line per tunnel, with the outside address and the two inside addresses it
# was given together, so a pair set against the wrong tunnel shows next to
# AWS's own listing.
status() {
  local n active link sa probe outside inside_local inside_remote status=0
  active="$(route_tunnel)"
  echo "VPN to $VPN_VPC_CIDR from $VPN_SITE_PRIVATE_ADDRESS (identity $VPN_SITE_PUBLIC_ADDRESS)"
  for n in 1 2; do
    link="$(tunnel_link "$n")"
    outside="VPN_TUNNEL${n}_OUTSIDE_ADDRESS"
    inside_local="VPN_TUNNEL${n}_INSIDE_LOCAL"
    inside_remote="VPN_TUNNEL${n}_INSIDE_REMOTE"
    if sa_up "$n"; then sa="established"; else sa="down"; fi
    if [ "$VPN_HEALTH_PING" = false ]; then
      probe="not probed"
    elif probe_answers "$n"; then
      probe="inside address answers"
    else
      probe="inside address does not answer"
    fi
    printf '  tunnel %s  outside %s  inside %s to %s  %s: %s, %s%s\n' "$n" "${!outside}" \
      "${!inside_local}" "${!inside_remote}" "$link" "$sa" "$probe" \
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

# --- down ------------------------------------------------------------------

# Undo what provisioning did, from whatever is left of it, so a second run and a
# run after a provisioning that stopped half-way both work. vpn.conf goes last:
# a down that stops on the way still finds the tunnel addresses in it. The
# packages stay installed, and so do the unit files, which every node's
# checkout installs and which do nothing without vpn.conf.
down() {
  local unit link file addresses address
  # The health timer first, so nothing puts a route back.
  for unit in "$HEALTH_TIMER" "$HEALTH_UNIT" "$BOOT_UNIT" "$STRONGSWAN_UNIT"; do
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      echo "  disabling and stopping $unit"
      systemctl disable --now "$unit" >/dev/null 2>&1 || die "could not disable $unit"
    elif systemctl is-active --quiet "$unit"; then
      echo "  stopping $unit"
      systemctl stop "$unit" || die "could not stop $unit"
    fi
  done

  if nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
    echo "  deleting nftables table $NFT_TABLE"
    nft delete table ip "$NFT_TABLE" || die "could not delete nftables table $NFT_TABLE"
  fi
  remove_vpn_routes
  for link in "$(tunnel_link 1)" "$(tunnel_link 2)" "$SITE_LINK"; do
    ip link show dev "$link" >/dev/null 2>&1 || continue
    echo "  removing $link"
    ip link del dev "$link" || die "could not remove $link"
  done

  addresses="$(admitted_addresses)" || die "could not read ufw status"
  for address in $addresses; do
    ipv4_to_int "$address" >/dev/null || continue
    ufw_rule delete proto udp from "$address" to any port 500,4500
    ufw_rule delete proto esp from "$address" to any
  done

  remove_staged_copies
  for file in $STRONGSWAN_FILES "$NFT_RULESET" "$RESTART_PENDING" "$VPN_CONF"; do
    cat "$file" >/dev/null 2>&1 || continue
    rm -f "$file" || die "could not remove $file"
    echo "  removed $file"
  done
  echo "VPN removed. strongSwan's packages stay installed."
}

case "${1:-}" in
  up | health | status | down)
    [ "$(id -u)" -eq 0 ] || die "must run as root"
    case "$1" in
      up)
        take_vpn_lock wait
        load_conf
        bring_up
        ;;
      health)
        if ! take_vpn_lock skip; then
          echo "a provisioning run holds $VPN_LOCK_FILE; skipping this check"
          exit 0
        fi
        load_conf
        health
        ;;
      status)
        load_conf
        status
        ;;
      down)
        take_deploy_lock
        take_vpn_lock wait
        down
        ;;
    esac
    exit
    ;;
  "") ;;
  -h | --help)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) die "unknown command '$1'; expected up, health, status, down or nothing" ;;
esac

# --- 1. Verify, changing nothing -------------------------------------------

[ "$(id -u)" -eq 0 ] || fail root "must run as root"

# Before anything else is read: the checkout this script runs from, and
# vpn.conf, which the health check reads under the VPN lock.
take_deploy_lock
take_vpn_lock wait

require_address() { # require_address <name>
  [ -n "${!1:-}" ] || fail inputs "set $1"
  ipv4_to_int "${!1}" >/dev/null || fail inputs "$1 is '${!1}', not an IPv4 address"
}

for name in VPN_SITE_PUBLIC_ADDRESS VPN_SITE_PRIVATE_ADDRESS VPN_TUNNEL1_OUTSIDE_ADDRESS \
  VPN_TUNNEL2_OUTSIDE_ADDRESS VPN_TUNNEL1_INSIDE_REMOTE VPN_TUNNEL2_INSIDE_REMOTE; do
  # The site's private address may come as central lists it, with its /32.
  if [ "$name" = VPN_SITE_PRIVATE_ADDRESS ]; then
    VPN_SITE_PRIVATE_ADDRESS="${VPN_SITE_PRIVATE_ADDRESS:-}"
    VPN_SITE_PRIVATE_ADDRESS="${VPN_SITE_PRIVATE_ADDRESS%/32}"
  fi
  require_address "$name"
done
: "${VPN_VPC_CIDR:=$STATED_VPC_CIDR}"
for name in VPN_VPC_CIDR VPN_TUNNEL1_INSIDE_LOCAL VPN_TUNNEL2_INSIDE_LOCAL; do
  [ -n "${!name:-}" ] || fail inputs "set $name"
  is_cidr "${!name}" || fail inputs "$name is '${!name}', not an IPv4 address with a prefix"
done
# AWS gives each tunnel a /30; any other prefix would route more than the
# tunnel's two inside addresses into it, the default route at /0.
for name in VPN_TUNNEL1_INSIDE_LOCAL VPN_TUNNEL2_INSIDE_LOCAL; do
  [ "${!name#*/}" = 30 ] || fail inputs "$name is '${!name}', not an IPv4 address with the prefix /30"
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
[ "$VPN_VPC_CIDR" = "$STATED_VPC_CIDR" ] || [ "${VPN_VPC_CIDR_OVERRIDE:-}" = true ] ||
  fail inputs "VPN_VPC_CIDR is $VPN_VPC_CIDR, but central's VPN document states $STATED_VPC_CIDR.
       Leave VPN_VPC_CIDR unset, or set VPN_VPC_CIDR_OVERRIDE=true to route another CIDR"
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
# Each tunnel needs a /30 of its own: on a shared one, both interfaces would
# claim the same connected route.
! overlaps "$VPN_TUNNEL1_INSIDE_LOCAL" "$VPN_TUNNEL2_INSIDE_LOCAL" ||
  fail inputs "VPN_TUNNEL1_INSIDE_LOCAL $VPN_TUNNEL1_INSIDE_LOCAL and VPN_TUNNEL2_INSIDE_LOCAL $VPN_TUNNEL2_INSIDE_LOCAL overlap"

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
    # bao_get needs only the OpenBao container and the host token, not the
    # node's checkout configuration.
    for n in 1 2; do
      value="$(bao_get vpn "tunnel${n}_psk")" || fail "pre-shared keys" "cannot read $FILONE_BAO_MOUNT/vpn#tunnel${n}_psk"
      printf -v "PSK$n" '%s' "$value"
    done
    ;;
  "")
    for n in 1 2; do
      file_var="VPN_TUNNEL${n}_PSK_FILE"
      [ -z "${!file_var:-}" ] ||
        fail inputs "$file_var is set but VPN_PSK_SOURCE is not; set VPN_PSK_SOURCE=files to install new keys"
    done
    # The keys a previous run installed, while they still belong to the same
    # two tunnel addresses.
    installed="$(cat "$SWANCTL_SECRETS" 2>/dev/null)" ||
      fail inputs "set VPN_PSK_SOURCE to files or openbao; this node has no installed keys to keep"
    for n in 1 2; do
      outside="VPN_TUNNEL${n}_OUTSIDE_ADDRESS"
      block="$(awk -v name="ike-tunnel$n" '$1 == name && $2 == "{" { on = 1; next } on && $1 == "}" { exit } on' \
        <<<"$installed")"
      id1="$(awk '$1 == "id-1" { print $3 }' <<<"$block")"
      id2="$(awk '$1 == "id-2" { print $3 }' <<<"$block")"
      [ "$id1" = "$VPN_SITE_PUBLIC_ADDRESS" ] && [ "$id2" = "${!outside}" ] ||
        fail "pre-shared keys" "tunnel $n's installed key belongs to ${id2:-no address} from ${id1:-no address},
       not ${!outside} from $VPN_SITE_PUBLIC_ADDRESS. Give the new keys with VPN_PSK_SOURCE=files"
      value="$(awk '$1 == "secret" { print $3 }' <<<"$block")"
      value="$(base64 -d <<<"${value#0s}" 2>/dev/null)" ||
        fail "pre-shared keys" "tunnel $n's installed key in $SWANCTL_SECRETS does not decode"
      printf -v "PSK$n" '%s' "$value"
    done
    unset installed block
    ;;
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

# strongSwan's packages, once the inputs pass, and only the missing ones.
missing_packages=""
for package in $STRONGSWAN_PACKAGES; do
  # shellcheck disable=SC2016 # dpkg-query's own field syntax
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' ||
    missing_packages="${missing_packages:+$missing_packages }$package"
done
if [ -n "$missing_packages" ]; then
  echo "  installing $missing_packages"
  # shellcheck disable=SC2086 # one word per package
  { DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null &&
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $missing_packages >/dev/null; } ||
    fail packages "could not install $missing_packages"
fi

for tool in swanctl ip nft ufw sysctl ping docker base64; do
  command -v "$tool" >/dev/null || fail tools "$tool is not installed"
done
[ "$(systemctl show -p LoadState --value "$STRONGSWAN_UNIT" 2>/dev/null)" = loaded ] ||
  fail strongswan "$STRONGSWAN_UNIT is not installed, though $STRONGSWAN_PACKAGES are"
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

# Nothing else may route the VPC or any part of it, and no address on the host
# may sit inside it. 'root' lists the VPC's own prefix and every longer one in it.
# This script's own unreachable routes, at the fallback metric, are exempt. ip
# ends each route line with a space, so the pattern allows trailing spaces.
existing_route="$(ip -4 route show root "$VPN_VPC_CIDR" | grep -v "^unreachable [^ ]* metric $FALLBACK_METRIC *\$" |
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
    # Either way round: a subnet wider than the VPC holds it whole, and the
    # tunnel's more specific route would take its containers' own addresses.
    if in_network "${subnet%/*}" "$VPN_VPC_CIDR" || in_network "${VPN_VPC_CIDR%/*}" "$subnet"; then
      fail "docker networks" "network '$network' uses $subnet, which overlaps $VPN_VPC_CIDR"
    fi
    # The same for each tunnel's inside /30, whose connected route would take
    # the containers' addresses it covers.
    for inside in "$VPN_TUNNEL1_INSIDE_LOCAL" "$VPN_TUNNEL2_INSIDE_LOCAL"; do
      if in_network "${subnet%/*}" "$inside" || in_network "${inside%/*}" "$subnet"; then
        fail "docker networks" "network '$network' uses $subnet, which overlaps the tunnel inside network $inside"
      fi
    done
    VPN_CLIENT_SOURCES="${VPN_CLIENT_SOURCES:+$VPN_CLIENT_SOURCES }$subnet"
  done
done
[ -n "$VPN_CLIENT_SOURCES" ] || fail "docker networks" "no IPv4 subnet on ${VPN_DOCKER_NETWORKS:-filone}"

# The outside addresses a previous run admitted, whose rules go if they changed:
# those vpn.conf names and any other whose rules carry this script's comment, so
# an address a stopped run admitted goes too though vpn.conf never recorded it.
previous_outside="$(admitted_addresses)" || die "could not read ufw status"

# --- 2. strongSwan's configuration, rendered --------------------------------
# Compared with what is installed here, and written only in section 4, once the
# firewall and the host network are applied.

# Routes come from this script, not from charon: with 0.0.0.0/0 traffic
# selectors, charon's own route would take every packet on the host.
charon_conf() {
  cat <<'CHARON'
# Written by scripts/host/setup-vpn.sh.
charon {
  install_routes = no
}
CHARON
}

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

file_mode() { # file_mode <file>
  if [ "$1" = "$CHARON_CONF" ]; then echo 0644; else echo 0600; fi
}

render_file() { # render_file <file>
  case "$1" in
    "$CHARON_CONF") charon_conf ;;
    "$SWANCTL_CONF") swanctl_connections ;;
    "$SWANCTL_SECRETS") swanctl_secrets ;;
    "$VPN_CONF") for key in $CONF_KEYS; do printf '%s=%s\n' "$key" "${!key}"; done ;;
  esac
}

restart_pending() { cat "$RESTART_PENDING" >/dev/null 2>&1; }

install -d -m 0755 /etc/fil-one /etc/swanctl/conf.d /etc/strongswan.d
install -d -m 0700 -o root -g root /run/fil-one /run/fil-one/secrets
remove_staged_copies

# A changed file means a restart. The marker records it before anything on the
# host changes, so a run that stops on the way leaves the restart to the next.
for file in $STRONGSWAN_FILES; do
  file_state "$(file_mode "$file")" "$file" < <(render_file "$file")
  if [ "$FILE_STATE" = content ]; then
    install -m 0600 -o root -g root /dev/null "$RESTART_PENDING" ||
      die "could not write $RESTART_PENDING"
    break
  fi
done

# --- 3. Firewall -----------------------------------------------------------

for old in $previous_outside; do
  ipv4_to_int "$old" >/dev/null || continue
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

# strongSwan's files and vpn.conf, which boot and the health check apply from
# now on, go in as one set so that a reboot after a failed run finds either all
# new or all old. Each changed file is written beside itself as <file>.new,
# which no include pattern matches, and only once all are written are they
# renamed into place, so a failed write leaves every one as it was. Each one
# being replaced is first copied beside itself as <file>.old, so a failed
# rename, which within one filesystem is close to impossible, puts back the
# files renamed before it, removes those it created, and leaves the set as it
# was. The restart marker cannot cover that case, since a reboot clears it and
# strongSwan then loads the files as they stand. A file whose mode or owner
# alone drifted is written again without a restart.
staged_files=""
for file in $STAGED_FILES; do
  mode="$(file_mode "$file")"
  stage_file "$mode" "$file" < <(render_file "$file")
  if [ "$FILE_STATE" != same ]; then
    if ! install -m "$mode" -o root -g root "$STAGED" "$file.new" || {
      cat "$file" >/dev/null 2>&1 && ! install -m "$mode" -o root -g root "$file" "$file.old"
    }; then
      rm -f "$STAGED" "$file.new" "$file.old"
      for staged in $staged_files; do rm -f "$staged.new" "$staged.old"; done
      die "could not write $file"
    fi
    staged_files="${staged_files:+$staged_files }$file"
  fi
  rm -f "$STAGED"
done
# A copy rm cannot remove is left for the next run's remove_staged_copies; the
# error that matters is the rename.
renamed=""
unmoved=""
for file in $staged_files; do
  if [ -n "$unmoved" ]; then
    rm -f "$file.new" "$file.old" || true
  elif mv -f "$file.new" "$file"; then
    renamed="${renamed:+$renamed }$file"
  else
    unmoved="$file"
    rm -f "$file.new" "$file.old" || true
  fi
done
if [ -n "$unmoved" ]; then
  unrestored=""
  for file in $renamed; do
    if cat "$file.old" >/dev/null 2>&1; then
      mv -f "$file.old" "$file"
    else
      rm -f "$file"
    fi || unrestored="${unrestored:+$unrestored }$file"
  done
  [ -z "$unrestored" ] ||
    die "could not move $unmoved.new into place, nor put back $unrestored; re-run before a reboot"
  die "could not move $unmoved.new into place; every file is as it was"
fi
for file in $renamed; do
  rm -f "$file.old" || true
  echo "  wrote $file"
done
unset PSK1 PSK2

# The routes boot and the health check no longer own.
remove_vpn_routes "$VPN_VPC_CIDR"

# --- 5. Units and strongSwan -----------------------------------------------

FILONE_CHECKOUT="$CHECKOUT"
sync_systemd_units

if restart_pending || ! systemctl is-active --quiet "$STRONGSWAN_UNIT"; then
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
connections="$(swanctl --list-conns)" || die "could not list charon's connections"
for n in 1 2; do
  grep -q "^tunnel$n: " <<<"$connections" ||
    die "charon did not load both tunnels from $SWANCTL_CONF; 'journalctl -u $STRONGSWAN_UNIT' says why"
done
# charon runs the configuration on disk, so the marker goes. Any failed check
# above has already stopped the run with the marker in place.
if restart_pending; then rm -f "$RESTART_PENDING"; fi

# The boot unit's 'up' takes the VPN lock, and the enable below starts it.
release_vpn_lock

for unit in "$BOOT_UNIT" "$HEALTH_TIMER"; do
  systemctl is-enabled --quiet "$unit" || {
    echo "  enabling $unit"
    systemctl enable --now "$unit" >/dev/null || die "could not enable $unit"
  }
done

echo "VPN provisioned. The tunnels come up as AWS answers; check them with:"
echo "  scripts/host/setup-vpn.sh status"
