#!/usr/bin/env bash
# Tests for scripts/host/setup-vpn.sh, run from any machine:
#
#   scripts/host/tests/setup-vpn.test.sh
#
# The script runs as root against the host's network stack, so here it runs
# against stubs. Each case puts stub ip, nft, ufw, swanctl, systemctl, sysctl,
# ping, docker and id commands first on PATH. They answer from files in a
# temporary directory and append every call to a log the assertions read. Stub
# install, cat, cmp and rm commands absorb the file reads and writes: a path
# under /etc, /run, /mnt, /var/lib or /root is moved under the case's own root
# directory. The script reads and writes those paths only through these
# commands, so nothing outside the temporary directory changes.
#
# Nothing here reaches a real gateway: the stubs stand in for strongSwan's SA
# state and the pings through each tunnel.
#
# Plain bash with no dependencies beyond the ones the script itself has, and
# written for the bash 3.2 macOS ships as well as for a current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../setup-vpn.sh"
REAL_CAT="$(command -v cat)"
REAL_CMP="$(command -v cmp)"
REAL_RM="$(command -v rm)"
REAL_MKTEMP="$(command -v mktemp)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/setup-vpn-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Documentation addresses (RFC 5737) for anything public, link-local /30s for
# the inside addresses, and private ranges no real configuration uses.
PUBLIC=192.0.2.10
TUNNEL1=198.51.100.1
TUNNEL2=198.51.100.2
TUNNEL3=198.51.100.3
INSIDE1_LOCAL=169.254.200.2/30
INSIDE1_REMOTE=169.254.200.1
INSIDE2_LOCAL=169.254.200.6/30
INSIDE2_REMOTE=169.254.200.5
# The VPC side central's VPN document states, which the script pins.
VPC=10.20.192.0/18
OTHER_VPC=10.99.0.0/18
SITE=10.98.0.7
CONTAINERS=172.31.0.0/16
# Two keys shaped like AWS's, made up for the test.
PSK1_VALUE=test_key.one_K9f2Lq7
PSK2_VALUE=test_key.two_X3m8Rv1

failures=0
current=""

pass() { printf '  ok   %s\n' "$current: $1"; }
flunk() {
  printf '  FAIL %s\n' "$current: $1"
  failures=$((failures + 1))
}
check() { # check <description> <command...>
  local description="$1"
  shift
  if "$@"; then pass "$description"; else flunk "$description"; fi
}

# --- Stubs -------------------------------------------------------------------

write_stubs() {
  local bin="$1" tool

  cat >"$bin/id" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -u ] && { cat "$STUB_STATE/uid"; exit 0; }
exit 1
STUB

  # Links are directories under $STUB_STATE/links holding type, if_id, mtu
  # and up files, and each link's addresses are lines in its addrs file. The
  # main routing table is $STUB_STATE/routes, one route per line as ip prints
  # it. Every call that changes something is logged.
  cat >"$bin/ip" <<'STUB'
#!/usr/bin/env bash
echo "ip $*" >>"$STUB_STATE/calls"
links="$STUB_STATE/links"
routes="$STUB_STATE/routes"
touch "$routes"
show_link() { # show_link <name> <details?>
  local dir="$links/$1" flags="NOARP" line
  [ -d "$dir" ] || { echo "Device \"$1\" does not exist." >&2; exit 1; }
  [ ! -e "$dir/up" ] || flags="$flags,UP,LOWER_UP"
  line="7: $1: <$flags> mtu $(cat "$dir/mtu") qdisc noqueue state UNKNOWN"
  if [ -n "$2" ]; then
    case "$(cat "$dir/type")" in
      xfrm) line="$line \\    link/none promiscuity 0 \\    xfrm if_id 0x$(cat "$dir/if_id") addrgenmode none" ;;
      dummy) line="$line \\    link/ether promiscuity 0 \\    dummy addrgenmode eui64" ;;
    esac
  fi
  echo "$line"
}
show_addrs() { # show_addrs <name>
  local address
  [ -f "$links/$1/addrs" ] || return 0
  while read -r address; do
    echo "7: $1    inet $address scope global $1\\       valid_lft forever"
  done <"$links/$1/addrs"
}
details=""
[ "$1" != -d ] || { details=1; shift; }
[ "$1" != -4 ] || shift
[ "$1" != -o ] || shift
case "$1 $2" in
  "route show")
    if [ "$3" = default ]; then echo "default via 192.0.2.1 dev eth0 proto static"; exit 0; fi
    if [ -z "${3:-}" ]; then
      echo "default via 192.0.2.1 dev eth0 proto static"
      cat "$routes"
      exit 0
    fi
    [ "$3" = exact ] || exit 2
    awk -v p="$4" '($1 == p) || ($1 == "unreachable" && $2 == p)' "$routes"
    ;;
  "route replace")
    if [ "$3" = unreachable ]; then
      grep -v "^unreachable $4 " "$routes" >"$routes.new" || true
      echo "unreachable $4 metric $6" >>"$routes.new"
    else
      grep -v "^$3 dev " "$routes" >"$routes.new" || true
      echo "$3 dev $5 scope link src $7" >>"$routes.new"
    fi
    mv "$routes.new" "$routes"
    ;;
  "route del")
    if [ "$3" = unreachable ]; then pattern="^unreachable $4 "; else pattern="^$3 dev $5 "; fi
    grep -q "$pattern" "$routes" || { echo "RTNETLINK answers: No such process" >&2; exit 2; }
    grep -v "$pattern" "$routes" >"$routes.new" || true
    mv "$routes.new" "$routes"
    ;;
  "link show") show_link "$4" "$details" ;;
  "link add")
    mkdir -p "$links/$3"
    echo 1500 >"$links/$3/mtu"
    echo "$5" >"$links/$3/type"
    [ "$5" != xfrm ] || echo "$9" >"$links/$3/if_id"
    ;;
  "link set")
    name="$4"
    shift 4
    while [ $# -gt 0 ]; do
      case "$1" in
        mtu) echo "$2" >"$links/$name/mtu"; shift ;;
        up) touch "$links/$name/up" ;;
      esac
      shift
    done
    ;;
  "link del") [ -d "$links/$4" ] || exit 1; rm -r "$links/$4" ;;
  "addr show")
    if [ "${3:-}" = dev ]; then show_addrs "$4"; exit 0; fi
    echo "2: eth0    inet $(cat "$STUB_STATE/eth0-address") brd + scope global eth0"
    for dir in "$links"/*; do [ -d "$dir" ] && show_addrs "$(basename "$dir")"; done
    ;;
  "addr flush") : >"$links/$4/addrs" ;;
  "addr add") echo "$3" >>"$links/$5/addrs" ;;
  *) echo "ip stub: unexpected $*" >&2; exit 2 ;;
esac
exit 0
STUB

  cat >"$bin/nft" <<'STUB'
#!/usr/bin/env bash
echo "nft $*" >>"$STUB_STATE/calls"
case "$1" in
  list) [ -e "$STUB_STATE/nft-loaded" ] ;;
  # Like nft, refuses a ruleset file that is not there, and any ruleset while
  # nft-refuses exists.
  -f)
    [ -f "$STUB_ROOT$2" ] && [ ! -e "$STUB_STATE/nft-refuses" ] || exit 1
    touch "$STUB_STATE/nft-loaded"
    ;;
  *) exit 2 ;;
esac
STUB

  # Rules are lines in $STUB_STATE/ufw-rules. Like ufw, an existing rule is
  # skipped and a missing one cannot be deleted. While ufw-delete-fails exists,
  # every delete fails as ufw does on an error of its own.
  cat >"$bin/ufw" <<'STUB'
#!/usr/bin/env bash
echo "ufw $*" >>"$STUB_STATE/calls"
rules="$STUB_STATE/ufw-rules"
touch "$rules"
case "$1" in
  status) cat "$STUB_STATE/ufw-status" ;;
  allow)
    shift
    rule="$(printf '%s\n' "$*" | sed 's/ comment .*//')"
    if grep -qxF "$rule" "$rules"; then echo "Skipping adding existing rule"; exit 0; fi
    echo "$rule" >>"$rules"
    echo "ufw-change allow $rule" >>"$STUB_STATE/calls"
    echo "Rule added"
    ;;
  delete)
    shift 2
    if [ -e "$STUB_STATE/ufw-delete-fails" ]; then echo "ERROR: problem running iptables" >&2; exit 1; fi
    if grep -qxF "$*" "$rules"; then
      grep -vxF "$*" "$rules" >"$rules.new" || true
      mv "$rules.new" "$rules"
      echo "ufw-change delete $*" >>"$STUB_STATE/calls"
      echo "Rule deleted"
    else
      echo "Could not delete non-existent rule"
    fi
    ;;
esac
STUB

  # A file sa-up-<n> makes tunnel n's SAs established and installed.
  cat >"$bin/swanctl" <<'STUB'
#!/usr/bin/env bash
echo "swanctl $*" >>"$STUB_STATE/calls"
case "$1" in
  --list-sas)
    name="$3"
    n="${name#tunnel}"
    [ -e "$STUB_STATE/sa-up-$n" ] || exit 0
    echo "$name: #$n, ESTABLISHED, IKEv2, 0123456789abcdef_i* fedcba9876543210_r"
    echo "  AES_GCM_16-256/PRF_HMAC_SHA2_384/ECP_384"
    echo "  $name: #$n, reqid $n, INSTALLED, TUNNEL, ESP:AES_GCM_16-256/ECP_384"
    ;;
  --list-algs) cat "$STUB_STATE/algs" ;;
  --list-conns) printf 'tunnel1: IKEv2, no reauthentication\ntunnel2: IKEv2, no reauthentication\n' ;;
esac
STUB

  cat >"$bin/ping" <<'STUB'
#!/usr/bin/env bash
echo "ping $*" >>"$STUB_STATE/calls"
while [ $# -gt 1 ]; do
  [ "$1" = -I ] && dev="$2"
  shift
done
[ -e "$STUB_STATE/ping-$dev" ]
STUB

  # Values are files under $STUB_STATE/sysctl; rp_filter reads 1 until set.
  cat >"$bin/sysctl" <<'STUB'
#!/usr/bin/env bash
echo "sysctl $*" >>"$STUB_STATE/calls"
dir="$STUB_STATE/sysctl"
mkdir -p "$dir"
case "$1" in
  -n) if [ -f "$dir/$2" ]; then cat "$dir/$2"; else echo 1; fi ;;
  -q) setting="$3"; echo "${setting#*=}" >"$dir/${setting%%=*}" ;;
esac
STUB

  # A file enabled-<unit> or active-<unit> holds that state.
  cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_STATE/calls"
quiet=""
case "$1" in
  show) [ -e "$STUB_STATE/no-strongswan" ] || echo loaded ;;
  is-active)
    [ "$2" != --quiet ] || { quiet=1; shift; }
    if [ -e "$STUB_STATE/active-$2" ]; then [ -n "$quiet" ] || echo active; exit 0; fi
    [ -n "$quiet" ] || echo inactive
    exit 3
    ;;
  is-enabled) [ -e "$STUB_STATE/enabled-$3" ]; exit ;;
  enable)
    if [ "$2" = --now ]; then touch "$STUB_STATE/enabled-$3" "$STUB_STATE/active-$3"
    else touch "$STUB_STATE/enabled-$2"; fi
    ;;
  restart) touch "$STUB_STATE/active-$2" ;;
esac
exit 0
STUB

  cat >"$bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_STATE/calls"
if [ "$1" = exec ]; then
  # bao kv get -mount=filone -field=<field> <path>: answers from bao-<path>-<field>.
  for arg in "$@"; do
    case "$arg" in -field=*) field="${arg#-field=}" ;; esac
  done
  [ -f "$STUB_STATE/bao-${*: -1}-$field" ] || exit 2
  cat "$STUB_STATE/bao-${*: -1}-$field"
  exit 0
fi
network="${*: -1}"
[ -f "$STUB_STATE/docker-network-$network" ] || exit 1
cat "$STUB_STATE/docker-network-$network"
STUB

  cat >"$bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

  # Writes land under $STUB_ROOT instead of on this machine. A file's mode and
  # owner go under $STUB_STATE/meta, where the stat stub reads them.
  cat >"$bin/install" <<'STUB'
#!/usr/bin/env bash
echo "install $*" >>"$STUB_STATE/calls"
mode=755
owner=0
case " $* " in *" -m "*) mode="$(printf '%s\n' "$*" | sed 's/.*-m \([0-7]*\).*/\1/')" ;; esac
case " $* " in *" -o root "*) ;; *" -o "*) owner=1000 ;; esac
destination="${*: -1}"
map() {
  case "$1" in
    /etc/*|/run/*|/mnt/*|/var/lib/*|/root/*) printf '%s%s' "$STUB_ROOT" "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
dirs=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -d) dirs=1 ;;
    -m|-o|-g) shift ;;
    *) args+=("$(map "$1")") ;;
  esac
  shift
done
if [ "$dirs" = 1 ]; then mkdir -p "${args[@]}"; exit; fi
mkdir -p "$(dirname "${args[1]}")"
cp "${args[0]}" "${args[1]}"
mkdir -p "$(dirname "$STUB_STATE/meta$destination")"
echo "${mode#0} $owner $owner" >"$STUB_STATE/meta$destination"
STUB

  # stat -c '%a %u %g' <path>, from what the install stub recorded.
  cat >"$bin/stat" <<'STUB'
#!/usr/bin/env bash
[ -f "$STUB_STATE/meta${*: -1}" ] || exit 1
cat "$STUB_STATE/meta${*: -1}"
STUB

  # cat, cmp, rm and mktemp run the real command on the moved paths.
  for tool in cat cmp rm mktemp; do
    cat >"$bin/$tool" <<STUB
#!/usr/bin/env bash
[ "$tool" != rm ] || echo "rm \$*" >>"\$STUB_STATE/calls"
map() {
  case "\$1" in
    /etc/*|/run/*|/mnt/*|/var/lib/*|/root/*) printf '%s%s' "\$STUB_ROOT" "\$1" ;;
    *) printf '%s' "\$1" ;;
  esac
}
args=()
for arg in "\$@"; do args+=("\$(map "\$arg")"); done
exec "\$REAL_$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')" \${args[@]+"\${args[@]}"}
STUB
  done

  chmod +x "$bin"/*
}

# --- A healthy host ----------------------------------------------------------

new_case() {
  current="$1"
  case_count=$((case_count + 1))
  CASE="$WORK/case-$case_count"
  STATE="$CASE/state"
  ROOT="$CASE/root"
  mkdir -p "$CASE/bin" "$STATE/links" "$ROOT" "$CASE/tmp" "$CASE/keys"
  write_stubs "$CASE/bin"
  : >"$STATE/calls"

  echo 0 >"$STATE/uid"
  echo "$PUBLIC/24" >"$STATE/eth0-address"
  echo "$CONTAINERS " >"$STATE/docker-network-filone"
  printf 'Status: active\nLogging: on (low)\nDefault: deny (incoming), allow (outgoing), deny (routed)\n' \
    >"$STATE/ufw-status"
  printf 'aead:\n  AES_GCM_16[gcm]\nprf:\n  PRF_HMAC_SHA2_384[openssl]\nke:\n  ECP_384[openssl]\n  ECP_521[openssl]\n' \
    >"$STATE/algs"
  printf '%s\n' "$PSK1_VALUE" >"$CASE/keys/psk1"
  printf '%s\n' "$PSK2_VALUE" >"$CASE/keys/psk2"

  INPUTS=(
    VPN_SITE_PUBLIC_ADDRESS="$PUBLIC"
    VPN_BEHIND_NAT=false
    VPN_SITE_PRIVATE_ADDRESS="$SITE/32"
    VPN_TUNNEL1_OUTSIDE_ADDRESS="$TUNNEL1"
    VPN_TUNNEL1_INSIDE_LOCAL="$INSIDE1_LOCAL"
    VPN_TUNNEL1_INSIDE_REMOTE="$INSIDE1_REMOTE"
    VPN_TUNNEL2_OUTSIDE_ADDRESS="$TUNNEL2"
    VPN_TUNNEL2_INSIDE_LOCAL="$INSIDE2_LOCAL"
    VPN_TUNNEL2_INSIDE_REMOTE="$INSIDE2_REMOTE"
    VPN_PSK_SOURCE=files
    VPN_TUNNEL1_PSK_FILE="$CASE/keys/psk1"
    VPN_TUNNEL2_PSK_FILE="$CASE/keys/psk2"
  )
}
case_count=0

# Replace one input, or with no value drop it.
set_input() { # set_input <name> [value]
  local kept=() entry
  for entry in "${INPUTS[@]}"; do
    [ "${entry%%=*}" = "$1" ] || kept+=("$entry")
  done
  [ $# -lt 2 ] || kept+=("$1=$2")
  INPUTS=("${kept[@]}")
}

# Runs the script with only the inputs in INPUTS, plus any arguments. TMPDIR
# points at the case's own directory unless NO_TMPDIR is set, as it is under
# systemd.
run_vpn() {
  local tmpdir=(TMPDIR="$CASE/tmp")
  [ -z "${NO_TMPDIR:-}" ] || tmpdir=()
  set +e
  env -i HOME="$CASE" PATH="$CASE/bin:$PATH" \
    STUB_STATE="$STATE" STUB_ROOT="$ROOT" ${tmpdir[@]+"${tmpdir[@]}"} \
    REAL_CAT="$REAL_CAT" REAL_CMP="$REAL_CMP" REAL_RM="$REAL_RM" REAL_MKTEMP="$REAL_MKTEMP" \
    "${INPUTS[@]}" bash "$SCRIPT" "$@" >"$CASE/stdout" 2>"$CASE/stderr"
  status=$?
  set -e
  cat "$CASE/stdout" "$CASE/stderr" >>"$CASE/all-output"
}

# --- Assertions --------------------------------------------------------------

called() { grep -qE "$1" "$STATE/calls"; }
not_called() { ! called "$1"; }
failed() { [ "$status" -ne 0 ]; }
succeeded() {
  [ "$status" -eq 0 ] || { sed 's/^/       /' "$CASE/stderr"; return 1; }
}
said() { grep -qF -- "$1" "$CASE/stderr"; }
printed() { grep -qF -- "$1" "$CASE/stdout"; }
in_file() { grep -qF -- "$2" "$ROOT$1"; }
not_in_file() { ! in_file "$@"; }
never_output() { ! grep -qF -- "$1" "$CASE/all-output"; }
# Every UFW rule added names one of the two tunnel addresses.
ufw_rules_only_for_tunnels() {
  ! grep '^ufw-change' "$STATE/calls" | grep -vqE "from ($TUNNEL1|$TUNNEL2) "
}
root_empty() { [ -z "$(ls -A "$ROOT")" ]; }
tmp_empty() { [ -z "$(ls -A "$CASE/tmp")" ]; }
root_files() { (cd "$ROOT" && find . -type f -exec cksum {} + | sort); }
route_is() { grep -qx "$VPC dev filone-tun$1 scope link src $SITE" "$STATE/routes"; }
fallback_present() { grep -qx "unreachable $VPC metric 4294967295" "$STATE/routes"; }
# One chain of the rendered nftables table.
nft_chain() { awk -v name="$1" '$1 == "chain" && $2 == name { on = 1 } on { print } on && $1 == "}" { exit }' "$ROOT/run/fil-one/vpn-nftables.conf"; }
chain_has() { nft_chain "$1" | grep -qxF -- "    $2"; }
TUNNELS='{ "filone-tun1", "filone-tun2" }'

# Anything that would change the host.
CHANGES='^(install -m|ip (link (add|set|del)|addr (add|flush)|route replace)|nft -f|sysctl -q|ufw-change|systemctl (restart|start|stop|enable|disable|daemon-reload)|rm .*/etc/)'
changed_nothing() { not_called "$CHANGES" && root_empty; }

# Neither key, nor its base64, in anything printed or in any command's argv.
key_never_shown() {
  local key
  for key in "$PSK1_VALUE" "$PSK2_VALUE" "$(printf '%s' "$PSK1_VALUE" | base64)" \
    "$(printf '%s' "$PSK2_VALUE" | base64)"; do
    ! grep -qF -- "$key" "$CASE/all-output" "$STATE/calls" || return 1
  done
}

expect_input_failure() { # expect_input_failure <check> <text in the message>
  run_vpn
  check "exits non-zero" failed
  check "names the check '$1'" said "check '$1' failed"
  check "says '$2'" said "$2"
  check "changes nothing" changed_nothing
  check "never shows a key" key_never_shown
}

echo "setup-vpn.sh"

# --- Refuses missing and wrong inputs ----------------------------------------

for name in VPN_SITE_PUBLIC_ADDRESS VPN_SITE_PRIVATE_ADDRESS \
  VPN_TUNNEL1_OUTSIDE_ADDRESS VPN_TUNNEL2_OUTSIDE_ADDRESS VPN_TUNNEL1_INSIDE_LOCAL \
  VPN_TUNNEL2_INSIDE_REMOTE VPN_BEHIND_NAT VPN_PSK_SOURCE; do
  new_case "missing $name"
  set_input "$name"
  expect_input_failure inputs "$name"
done

new_case "missing tunnel 2's key file"
set_input VPN_TUNNEL2_PSK_FILE
expect_input_failure "pre-shared keys" VPN_TUNNEL2_PSK_FILE

new_case "unreadable key file"
set_input VPN_TUNNEL1_PSK_FILE "$CASE/keys/absent"
expect_input_failure "pre-shared keys" "cannot read $CASE/keys/absent"

new_case "a key with a space in it"
printf 'test key with spaces\n' >"$CASE/keys/psk1"
expect_input_failure "pre-shared keys" "tunnel 1's key holds whitespace"
check "does not print the key" never_output "test key with spaces"

new_case "the same key on both tunnels"
cp "$CASE/keys/psk1" "$CASE/keys/psk2"
expect_input_failure "pre-shared keys" "the two tunnels have the same key"

new_case "an outside address that is not an address"
set_input VPN_TUNNEL1_OUTSIDE_ADDRESS 198.51.100.300
expect_input_failure inputs "not an IPv4 address"

new_case "an outside address with a leading zero"
# nft and strongSwan would read 010 as octal 8.
set_input VPN_TUNNEL1_OUTSIDE_ADDRESS 198.51.100.010
expect_input_failure inputs "not an IPv4 address"

new_case "an inside local address with a prefix other than /30"
set_input VPN_TUNNEL1_INSIDE_LOCAL 169.254.200.2/0
expect_input_failure inputs "VPN_TUNNEL1_INSIDE_LOCAL is '169.254.200.2/0', not an IPv4 address with the prefix /30"

new_case "a VPC CIDR with host bits"
set_input VPN_VPC_CIDR 10.20.192.1/18
expect_input_failure inputs "host bits"

new_case "a VPC CIDR other than central's"
set_input VPN_VPC_CIDR "$OTHER_VPC"
expect_input_failure inputs "VPN_VPC_CIDR_OVERRIDE"

new_case "the site address inside the VPC"
set_input VPN_SITE_PRIVATE_ADDRESS 10.20.192.7
expect_input_failure inputs "is inside VPN_VPC_CIDR"

new_case "an inside remote outside its /30"
set_input VPN_TUNNEL2_INSIDE_REMOTE 169.254.200.9
expect_input_failure inputs "is not another address in VPN_TUNNEL2_INSIDE_LOCAL"

new_case "VPN_BEHIND_NAT neither true nor false"
set_input VPN_BEHIND_NAT maybe
expect_input_failure inputs "must be true or false"

new_case "public address not on the host and not behind NAT"
echo 203.0.113.5/24 >"$STATE/eth0-address"
expect_input_failure "public address" "is not on this host"

new_case "something else routes the VPC"
echo "$VPC via 192.0.2.1 dev eth0" >"$STATE/routes"
expect_input_failure routes "something else routes $VPC"

new_case "no strongSwan"
touch "$STATE/no-strongswan"
expect_input_failure strongswan "libstrongswan-standard-plugins"

new_case "UFW denies outgoing"
printf 'Status: active\nDefault: deny (incoming), deny (outgoing), deny (routed)\n' >"$STATE/ufw-status"
expect_input_failure ufw "outgoing"

new_case "no filone Docker network"
rm "$STATE/docker-network-filone"
expect_input_failure "docker networks" "no Docker network 'filone'"

new_case "not root"
echo 1000 >"$STATE/uid"
run_vpn
check "exits non-zero" failed
check "changes nothing" changed_nothing

# --- A first run, then a second ----------------------------------------------

new_case "first run"
run_vpn
check "succeeds" succeeded
SWAN=/etc/swanctl/conf.d/filone-vpn.conf
SECRETS=/etc/swanctl/conf.d/filone-vpn-secrets.conf
check "renders tunnel 1 to its outside address" in_file "$SWAN" "remote_addrs = $TUNNEL1"
check "renders tunnel 2 to its outside address" in_file "$SWAN" "remote_addrs = $TUNNEL2"
check "renders exactly two connections" test "$(grep -c '^  tunnel[12] {' "$ROOT$SWAN")" -eq 2
check "binds tunnel 1 to if_id 1" in_file "$SWAN" "if_id_out = 1"
check "binds tunnel 2 to if_id 2" in_file "$SWAN" "if_id_out = 2"
check "pins the IKE proposal" in_file "$SWAN" "proposals = aes256gcm16-prfsha384-ecp384-ecp521"
check "pins the ESP proposal" in_file "$SWAN" "esp_proposals = aes256gcm16-ecp384-ecp521"
check "speaks IKEv2 only" test "$(grep -c 'version = 2' "$ROOT$SWAN")" -eq 2
check "identifies as the public address" in_file "$SWAN" "id = $PUBLIC"
check "pins the local address on the host" in_file "$SWAN" "local_addrs = $PUBLIC"
check "keeps the keys out of the connections file" not_in_file "$SWAN" secret
check "writes tunnel 1's key, base64-encoded" \
  in_file "$SECRETS" "secret = 0s$(printf '%s' "$PSK1_VALUE" | base64)"
check "writes tunnel 2's key, base64-encoded" \
  in_file "$SECRETS" "secret = 0s$(printf '%s' "$PSK2_VALUE" | base64)"
check "writes the keys at 0600" called "^install -m 0600 -o root -g root [^ ]+ $SECRETS$"
check "writes vpn.conf at 0600" called '^install -m 0600 -o root -g root [^ ]+ /etc/fil-one/vpn.conf$'
check "turns off charon's own routes" in_file /etc/strongswan.d/zz-filone-vpn.conf "install_routes = no"
check "creates tunnel 1's xfrm interface" called '^ip link add filone-tun1 type xfrm dev eth0 if_id 1$'
check "creates tunnel 2's xfrm interface" called '^ip link add filone-tun2 type xfrm dev eth0 if_id 2$'
check "sets the tunnel MTU" test "$(cat "$STATE/links/filone-tun1/mtu")" = 1446
check "puts the inside address on tunnel 1" grep -qx "$INSIDE1_LOCAL" "$STATE/links/filone-tun1/addrs"
check "puts the /32 on the dummy interface" grep -qx "$SITE/32" "$STATE/links/filone-site/addrs"
check "sets loose rp_filter on both tunnels" \
  test "$(cat "$STATE/sysctl/net.ipv4.conf.filone-tun1.rp_filter")$(cat "$STATE/sysctl/net.ipv4.conf.filone-tun2.rp_filter")" = 22
check "routes the VPC into tunnel 1 from the /32" route_is 1
check "routes nothing else into a tunnel" test "$(grep -c 'dev filone-tun' "$STATE/routes")" -eq 1
check "keeps an unreachable fallback route" grep -qx "unreachable $VPC metric 4294967295" "$STATE/routes"
NFT=/run/fil-one/vpn-nftables.conf
check "source-NATs VPC traffic to the /32" in_file "$NFT" "ip daddr $VPC ip saddr != $SITE snat to $SITE"
check "NATs before Docker's masquerade" in_file "$NFT" "priority srcnat - 10"
check "admits the filone network's containers" in_file "$NFT" "elements = { $CONTAINERS }"
check "clamps the MSS of SYNs into the tunnels" \
  chain_has forward "oifname $TUNNELS tcp flags syn / syn,rst tcp option maxseg size > 1406 tcp option maxseg size set 1406"
check "clamps the MSS of SYNs out of the tunnels" \
  chain_has forward "iifname $TUNNELS tcp flags syn / syn,rst tcp option maxseg size > 1406 tcp option maxseg size set 1406"
check "drops new connections from the tunnels to the host" chain_has input "iifname $TUNNELS drop"
check "admits replies from the tunnels to the host" chain_has input "iifname $TUNNELS ct state established,related accept"
check "loads the nftables table" called "^nft -f $NFT$"
check "admits IKE from tunnel 1" called "^ufw allow proto udp from $TUNNEL1 to any port 500,4500 comment"
check "admits ESP from tunnel 2" called "^ufw allow proto esp from $TUNNEL2 to any comment"
check "adds exactly four UFW rules" test "$(grep -c '^ufw-change allow' "$STATE/calls")" -eq 4
check "adds no UFW rule for any other address" ufw_rules_only_for_tunnels
check "starts strongSwan" called '^systemctl restart strongswan.service$'
check "checks charon's algorithms" called '^swanctl --list-algs$'
check "enables the boot unit" called '^systemctl enable --now filone-vpn.service$'
check "enables the health timer" called '^systemctl enable --now filone-vpn-health.timer$'
check "installs the units" test -f "$ROOT/etc/systemd/system/filone-vpn-health.timer"
check "never shows a key" key_never_shown
check "leaves no temporary file" tmp_empty

current="second run"
: >"$STATE/calls"
before="$(root_files)"
run_vpn
check "succeeds" succeeded
check "changes nothing" not_called "$CHANGES"
check "leaves every file as it was" test "$(root_files)" = "$before"
check "never shows a key" key_never_shown

current="status"
touch "$STATE/sa-up-1" "$STATE/sa-up-2" "$STATE/ping-filone-tun1" "$STATE/ping-filone-tun2"
run_vpn status
check "succeeds" succeeded
check "says tunnel 1 carries the route" printed "established, inside address answers, carries the route"
check "pairs tunnel 1's inside addresses with its outside address" \
  printed "tunnel 1  outside $TUNNEL1  inside $INSIDE1_LOCAL to $INSIDE1_REMOTE"
check "pairs tunnel 2's inside addresses with its outside address" \
  printed "tunnel 2  outside $TUNNEL2  inside $INSIDE2_LOCAL to $INSIDE2_REMOTE"
check "never shows a key" key_never_shown

# --- Failover ----------------------------------------------------------------

current="health with both tunnels up"
: >"$STATE/calls"
run_vpn health
check "succeeds" succeeded
check "leaves the route alone" not_called '^ip route replace'
check "keeps tunnel 1" route_is 1

current="health with the fallback route gone"
grep -v '^unreachable ' "$STATE/routes" >"$STATE/routes.new"
mv "$STATE/routes.new" "$STATE/routes"
run_vpn health
check "succeeds" succeeded
check "restores the fallback route" fallback_present
check "says so" printed "fallback route"
check "keeps tunnel 1" route_is 1

current="health with tunnel 1 down"
rm "$STATE/sa-up-1"
run_vpn health
check "succeeds" succeeded
check "moves the route to tunnel 2" route_is 2
check "says so" printed "moved the database route to tunnel 2"

current="health with tunnel 2 answering no pings"
touch "$STATE/sa-up-1"
rm "$STATE/ping-filone-tun2"
run_vpn health
check "succeeds" succeeded
check "moves the route back to tunnel 1" route_is 1

current="health with both tunnels down"
rm "$STATE/sa-up-1" "$STATE/sa-up-2"
: >"$STATE/calls"
run_vpn health
check "exits non-zero" failed
check "says both are down" said "both tunnels are down"
check "leaves the route where it was" route_is 1
check "changes no route" not_called '^ip route replace'

current="status with both tunnels down"
run_vpn status
check "exits non-zero" failed
check "says the route's tunnel is down" printed "the tunnel carrying the route is down"

current="up after a reboot"
rm -r "$STATE/links" "$STATE/nft-loaded"
mkdir -p "$STATE/links"
: >"$STATE/routes"
rm -rf "$ROOT/run"
run_vpn up
check "succeeds" succeeded
check "recreates tunnel 2's interface" called '^ip link add filone-tun2 type xfrm dev eth0 if_id 2$'
check "reloads the nftables table" called '^nft -f /run/fil-one/vpn-nftables.conf$'
check "routes the VPC into tunnel 1" route_is 1

current="up after a reboot, as systemd runs it"
rm -r "$STATE/links" "$STATE/nft-loaded"
mkdir -p "$STATE/links"
: >"$STATE/routes"
rm -rf "$ROOT/run"
NO_TMPDIR=1 run_vpn up
check "succeeds" succeeded
check "reloads the nftables table" called '^nft -f /run/fil-one/vpn-nftables.conf$'
check "routes the VPC into tunnel 1" route_is 1
check "writes the ruleset" test -f "$ROOT/run/fil-one/vpn-nftables.conf"
check "leaves no temporary file" test -z "$(ls -A "$ROOT/run/fil-one/secrets")"

new_case "another VPC CIDR, with the override"
set_input VPN_VPC_CIDR "$OTHER_VPC"
set_input VPN_VPC_CIDR_OVERRIDE true
run_vpn
check "succeeds" succeeded
check "routes that CIDR into tunnel 1" grep -qx "$OTHER_VPC dev filone-tun1 scope link src $SITE" "$STATE/routes"

# --- Keys --------------------------------------------------------------------

new_case "keys from OpenBao"
set_input VPN_PSK_SOURCE openbao
set_input VPN_TUNNEL1_PSK_FILE
set_input VPN_TUNNEL2_PSK_FILE
mkdir -p "$ROOT/etc/fil-one"
echo test-host-token >"$ROOT/etc/fil-one/bao-token"
printf '%s' "$PSK1_VALUE" >"$STATE/bao-vpn-tunnel1_psk"
printf '%s' "$PSK2_VALUE" >"$STATE/bao-vpn-tunnel2_psk"
run_vpn
check "succeeds" succeeded
check "reads tunnel 1's key from filone/vpn" called '^docker exec .* bao kv get -mount=filone -field=tunnel1_psk vpn$'
check "writes tunnel 1's key, base64-encoded" \
  in_file "$SECRETS" "secret = 0s$(printf '%s' "$PSK1_VALUE" | base64)"
check "writes tunnel 2's key, base64-encoded" \
  in_file "$SECRETS" "secret = 0s$(printf '%s' "$PSK2_VALUE" | base64)"
check "never shows a key" key_never_shown

new_case "a key missing from OpenBao"
set_input VPN_PSK_SOURCE openbao
mkdir -p "$ROOT/etc/fil-one"
echo test-host-token >"$ROOT/etc/fil-one/bao-token"
printf '%s' "$PSK1_VALUE" >"$STATE/bao-vpn-tunnel1_psk"
run_vpn
check "exits non-zero" failed
check "names the path" said "filone/vpn#tunnel2_psk"
check "changes nothing" not_called "$CHANGES"
check "never shows a key" key_never_shown

new_case "a re-run from the installed keys"
run_vpn
check "provisions" succeeded
set_input VPN_PSK_SOURCE
set_input VPN_TUNNEL1_PSK_FILE
set_input VPN_TUNNEL2_PSK_FILE
rm "$CASE/keys/psk1" "$CASE/keys/psk2"
: >"$STATE/calls"
before="$(root_files)"
run_vpn
check "succeeds" succeeded
check "changes nothing" not_called "$CHANGES"
check "leaves every file as it was" test "$(root_files)" = "$before"
check "never shows a key" key_never_shown
set_input VPN_TUNNEL_MTU 1400
run_vpn
check "applies a change that is not a key" succeeded
check "keeps the keys" in_file "$SECRETS" "secret = 0s$(printf '%s' "$PSK2_VALUE" | base64)"
check "sets the new MTU" test "$(cat "$STATE/links/filone-tun1/mtu")" = 1400

current="installed keys after a tunnel address change"
set_input VPN_TUNNEL2_OUTSIDE_ADDRESS "$TUNNEL3"
: >"$STATE/calls"
run_vpn
check "exits non-zero" failed
check "names the check 'pre-shared keys'" said "check 'pre-shared keys' failed"
check "says the key belongs to the old address" said "$TUNNEL2"
check "changes nothing" not_called "$CHANGES"
check "never shows a key" key_never_shown

new_case "key files with no key source"
set_input VPN_PSK_SOURCE
expect_input_failure inputs "VPN_PSK_SOURCE=files"

new_case "health with pings off"
set_input VPN_HEALTH_PING false
run_vpn
check "provisions" succeeded
touch "$STATE/sa-up-2"
run_vpn health
check "moves the route on SA state alone" route_is 2
check "sends no ping" not_called '^ping '

# --- Changes -----------------------------------------------------------------

new_case "a new tunnel address"
run_vpn
check "provisions" succeeded
set_input VPN_TUNNEL2_OUTSIDE_ADDRESS "$TUNNEL3"
: >"$STATE/calls"
run_vpn
check "succeeds" succeeded
check "removes the old address's IKE rule" called "^ufw-change delete proto udp from $TUNNEL2 to any port 500,4500$"
check "removes the old address's ESP rule" called "^ufw-change delete proto esp from $TUNNEL2 to any$"
check "admits the new address" called "^ufw-change allow proto udp from $TUNNEL3 to any port 500,4500$"
check "keeps tunnel 1's rules" not_called "^ufw-change delete .* $TUNNEL1 "
check "renders the new address" in_file "$SWAN" "remote_addrs = $TUNNEL3"
check "restarts strongSwan" called '^systemctl restart strongswan.service$'
check "leaves the interfaces alone" not_called '^ip link (add|del)'

new_case "a new VPC CIDR"
run_vpn
check "provisions" succeeded
set_input VPN_VPC_CIDR "$OTHER_VPC"
set_input VPN_VPC_CIDR_OVERRIDE true
run_vpn
check "succeeds" succeeded
check "routes the new CIDR into tunnel 1" grep -qx "$OTHER_VPC dev filone-tun1 scope link src $SITE" "$STATE/routes"
check "keeps a fallback for the new CIDR" grep -qx "unreachable $OTHER_VPC metric 4294967295" "$STATE/routes"
check "removes the old CIDR's tunnel route" test -z "$(grep "^$VPC dev " "$STATE/routes")"
check "removes the old CIDR's fallback" test -z "$(grep "^unreachable $VPC " "$STATE/routes")"
check "keeps the default route" not_called '^ip route del default'

new_case "a key file whose mode drifted"
run_vpn
check "provisions" succeeded
echo "644 0 0" >"$STATE/meta$SECRETS"
: >"$STATE/calls"
run_vpn
check "succeeds" succeeded
check "reinstalls the keys at 0600" called "^install -m 0600 -o root -g root [^ ]+ $SECRETS$"
check "leaves the file root-only" test "$(cat "$STATE/meta$SECRETS")" = "600 0 0"
check "never shows a key" key_never_shown

new_case "UFW fails to delete an old address's rule"
run_vpn
check "provisions" succeeded
set_input VPN_TUNNEL2_OUTSIDE_ADDRESS "$TUNNEL3"
touch "$STATE/ufw-delete-fails"
run_vpn
check "exits non-zero" failed
check "says ufw refused the delete" said "ufw refused: delete allow proto udp from $TUNNEL2"
check "keeps the old address in vpn.conf for the next run" \
  in_file /etc/fil-one/vpn.conf "VPN_TUNNEL2_OUTSIDE_ADDRESS=$TUNNEL2"
rm "$STATE/ufw-delete-fails"
: >"$STATE/calls"
run_vpn
check "a re-run succeeds" succeeded
check "and removes the old address's IKE rule" called "^ufw-change delete proto udp from $TUNNEL2 to any port 500,4500$"
check "and its ESP rule" called "^ufw-change delete proto esp from $TUNNEL2 to any$"
check "then records the new address" in_file /etc/fil-one/vpn.conf "VPN_TUNNEL2_OUTSIDE_ADDRESS=$TUNNEL3"

new_case "nft refuses a changed ruleset"
run_vpn
check "provisions" succeeded
set_input VPN_TUNNEL_MTU 1400
touch "$STATE/nft-refuses"
run_vpn
check "exits non-zero" failed
check "says nft refused it" said "nft refused"
check "leaves no refused ruleset behind" test ! -e "$ROOT/run/fil-one/vpn-nftables.conf"
check "keeps the last applied vpn.conf for the next boot" in_file /etc/fil-one/vpn.conf "VPN_TUNNEL_MTU=1446"
rm "$STATE/nft-refuses"
: >"$STATE/calls"
run_vpn
check "a re-run succeeds" succeeded
check "and loads the ruleset" called "^nft -f $NFT$"
check "and records the new MTU" in_file /etc/fil-one/vpn.conf "VPN_TUNNEL_MTU=1400"

new_case "behind NAT"
set_input VPN_BEHIND_NAT true
echo 10.0.5.20/24 >"$STATE/eth0-address"
run_vpn
check "succeeds" succeeded
check "uses the NAT-traversal MTU" test "$(cat "$STATE/links/filone-tun1/mtu")" = 1438
check "clamps the MSS to match" in_file /run/fil-one/vpn-nftables.conf "maxseg size set 1398"
check "leaves the local address to strongSwan" not_in_file "$SWAN" local_addrs
check "still identifies as the public address" in_file "$SWAN" "id = $PUBLIC"

new_case "charon without the GCM plugin"
printf 'prf:\n  PRF_HMAC_SHA2_384[openssl]\nke:\n  ECP_384[openssl]\n  ECP_521[openssl]\n' >"$STATE/algs"
run_vpn
check "exits non-zero" failed
check "names the missing package" said "libstrongswan-standard-plugins"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
