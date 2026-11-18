#!/usr/bin/env bash
# Tests for scripts/host/import-firewall.sh, run from any machine:
#
#   scripts/host/tests/import-firewall.test.sh
#
# The script runs as root against the host's nftables, so here it runs against
# stubs. Each case puts stub nft, ufw, iptables and id commands first on PATH;
# they answer from files in a temporary directory and append every call to a
# log the assertions read. Stub install, cat, cmp, rm and mktemp commands move
# any path under /etc or /run under the case's own root directory. The script
# reads and writes those paths only through these commands, so nothing outside
# the temporary directory changes.
#
# Plain bash, written for the bash 3.2 macOS ships as well as for a current one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../import-firewall.sh"
NODES="$(cd "$HERE/../../../nodes" && pwd)"
REAL_CAT="$(command -v cat)"
REAL_CMP="$(command -v cmp)"
REAL_RM="$(command -v rm)"
REAL_MKTEMP="$(command -v mktemp)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/import-firewall-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Documentation addresses (RFC 5737).
CLIENT1=192.0.2.21
CLIENT2=198.51.100.0/28
CLIENT3=203.0.113.9

CLIENTS_FILE=/etc/fil-one/import-clients
RULESET=/run/fil-one/import-nftables.conf

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

  # The loaded table is a copy of the last file `nft -f` read, in
  # $STUB_STATE/nft-loaded. A file nft-refuses makes every load fail, as nft
  # does on a ruleset it cannot parse.
  cat >"$bin/nft" <<'STUB'
#!/usr/bin/env bash
echo "nft $*" >>"$STUB_STATE/calls"
case "$1" in
  list) [ "$*" = "list table ip filone_import" ] || exit 2; [ -e "$STUB_STATE/nft-loaded" ] ;;
  -f)
    [ ! -e "$STUB_STATE/nft-refuses" ] || { echo "Error: syntax error" >&2; exit 1; }
    [ -f "$STUB_ROOT$2" ] || exit 1
    cp "$STUB_ROOT$2" "$STUB_STATE/nft-loaded"
    ;;
  *) exit 2 ;;
esac
STUB

  # The firewall tools the script must never call.
  for tool in ufw iptables ip6tables iptables-nft; do
    # shellcheck disable=SC2016 # expanded by the stub, not here
    printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_STATE/calls"\n' "$tool" >"$bin/$tool"
  done

  # Writes land under $STUB_ROOT instead of on this machine.
  cat >"$bin/install" <<'STUB'
#!/usr/bin/env bash
echo "install $*" >>"$STUB_STATE/calls"
map() {
  case "$1" in
    /etc/*|/run/*) printf '%s%s' "$STUB_ROOT" "$1" ;;
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
STUB

  # cat, cmp, rm and mktemp run the real command on the moved paths.
  for tool in cat cmp rm mktemp; do
    cat >"$bin/$tool" <<STUB
#!/usr/bin/env bash
map() {
  case "\$1" in
    /etc/*|/run/*) printf '%s%s' "\$STUB_ROOT" "\$1" ;;
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

# --- Cases -------------------------------------------------------------------

new_case() {
  current="$1"
  case_count=$((case_count + 1))
  CASE="$WORK/case-$case_count"
  STATE="$CASE/state"
  ROOT="$CASE/root"
  mkdir -p "$CASE/bin" "$STATE" "$ROOT/etc/fil-one" "$ROOT/run/fil-one/secrets" "$CASE/tmp"
  write_stubs "$CASE/bin"
  : >"$STATE/calls"
  echo 0 >"$STATE/uid"
}
case_count=0

clients() { # clients <line...>: the host-local client list
  printf '%s\n' "$@" >"$ROOT$CLIENTS_FILE"
}

run_firewall() {
  set +e
  env -i HOME="$CASE" PATH="$CASE/bin:$PATH" TMPDIR="$CASE/tmp" \
    STUB_STATE="$STATE" STUB_ROOT="$ROOT" \
    REAL_CAT="$REAL_CAT" REAL_CMP="$REAL_CMP" REAL_RM="$REAL_RM" REAL_MKTEMP="$REAL_MKTEMP" \
    bash "$SCRIPT" "$@" >"$CASE/stdout" 2>"$CASE/stderr"
  status=$?
  set -e
}

# --- Assertions --------------------------------------------------------------

failed() { [ "$status" -ne 0 ]; }
succeeded() {
  [ "$status" -eq 0 ] || { sed 's/^/       /' "$CASE/stderr"; return 1; }
}
said() { grep -qF -- "$1" "$CASE/stderr"; }
printed() { grep -qF -- "$1" "$CASE/stdout"; }
called() { grep -qE "$1" "$STATE/calls"; }
not_called() { ! called "$1"; }
loads() { grep -c '^nft -f ' "$STATE/calls" || true; }
loaded_has() { grep -qxF -- "$1" "$STATE/nft-loaded"; }
loaded_lacks() { ! grep -qF -- "$1" "$STATE/nft-loaded"; }
ruleset_has() { grep -qxF -- "$1" "$ROOT$RULESET"; }
no_ruleset() { [ ! -e "$ROOT$RULESET" ]; }
nothing_loaded() { [ ! -e "$STATE/nft-loaded" ]; }
DROP='    ct direction original ct status dnat tcp dport 8443 ip saddr != @clients drop'
# Every table the ruleset names is the script's own, and no other firewall tool
# is ever called.
only_own_table() {
  ! grep -E '^ *table ' "$ROOT$RULESET" | grep -vqE '^ *table ip filone_import( \{)?$' &&
    ! grep -E 'delete|flush' "$ROOT$RULESET" | grep -vqxF 'delete table ip filone_import' &&
    not_called '^(ufw|iptables|ip6tables|iptables-nft) ' &&
    ! grep '^nft ' "$STATE/calls" | grep -vqE '^nft (list table ip filone_import|-f /run/fil-one/import-nftables\.conf)$'
}
tmp_empty() { [ -z "$(ls -A "$CASE/tmp")" ]; }

# --- An empty or missing list ------------------------------------------------

echo "==> no clients"

new_case "no client list"
run_firewall
check "succeeds" succeeded
check "says the port is closed to every address" said "closed to every address"
check "loads the table" loaded_has "table ip filone_import {"
check "drops the service's port from everyone not listed" loaded_has "$DROP"
check "lists no client" loaded_lacks "elements"
check "touches nothing but its own table" only_own_table
check "leaves no temporary file" tmp_empty

new_case "only comments and blank lines"
clients "# the boxes that import" "" "   " "# none yet"
run_firewall
check "succeeds" succeeded
check "says the port is closed to every address" said "closed to every address"
check "lists no client" loaded_lacks "elements"
check "drops the service's port from everyone" loaded_has "$DROP"

# --- A list --------------------------------------------------------------------

echo "==> clients"

new_case "two clients"
clients "# the clients" "$CLIENT1" "  $CLIENT2  "
run_firewall
check "succeeds" succeeded
check "admits both" loaded_has "    elements = { $CLIENT1, $CLIENT2 }"
check "drops everyone else" loaded_has "$DROP"
check "names them" printed "$CLIENT1 $CLIENT2"
check "writes the ruleset root-only" called "^install -m 0600 -o root -g root .* $RULESET$"
check "touches nothing but its own table" only_own_table
first="$(cat "$ROOT$RULESET")"

run_firewall
check "a second run succeeds" succeeded
check "a second run loads nothing" test "$(loads)" -eq 1
check "a second run leaves the ruleset as it was" test "$(cat "$ROOT$RULESET")" = "$first"
check "a second run says it changed nothing" printed "unchanged"

clients "$CLIENT2" "$CLIENT3"
run_firewall
check "a changed list succeeds" succeeded
check "a changed list loads again" test "$(loads)" -eq 2
check "the address taken off the list is no longer admitted" loaded_lacks "$CLIENT1"
check "the remaining and the new one are" loaded_has "    elements = { $CLIENT2, $CLIENT3 }"
check "the old table goes in the same load" ruleset_has "delete table ip filone_import"

clients "# all removed"
run_firewall
check "emptying the list succeeds" succeeded
check "emptying the list loads again" test "$(loads)" -eq 3
check "emptying the list admits no one" loaded_lacks "elements"
check "emptying the list says the port is closed" said "closed to every address"

new_case "table gone while the list stayed"
clients "$CLIENT1"
run_firewall
rm -f "$STATE/nft-loaded"
run_firewall
check "succeeds" succeeded
check "loads the table again" test "$(loads)" -eq 2
check "with the same client" loaded_has "    elements = { $CLIENT1 }"

new_case "the port matches the service's published container port"
compose="$NODES/prod/us-east-2/apps/compose.yml"
check "prod/us-east-2 publishes the service on container port 8443" \
  grep -qE '^      - "0\.0\.0\.0:\$\{IMPORT_SERVICE_PORT\}:8443"$' "$compose"
check "and the service listens there" grep -qE '^      SPIDEROAK_IMPORT_PORT: "8443"$' "$compose"

# --- Refusals ------------------------------------------------------------------

echo "==> refusals"

refuses() { # refuses <description> <message> <line...>
  local description="$1" message="$2"
  shift 2
  new_case "$description"
  clients "$CLIENT3"
  run_firewall
  local before
  before="$(cat "$ROOT$RULESET")"
  clients "$@"
  run_firewall
  check "fails" failed
  check "says why" said "$message"
  check "keeps the ruleset" test "$(cat "$ROOT$RULESET")" = "$before"
  check "loads nothing" test "$(loads)" -eq 1
  check "still admits only the earlier list" loaded_has "    elements = { $CLIENT3 }"
}

refuses "an octet over 255" "not an IPv4 address or network" "$CLIENT1" "192.0.2.256"
refuses "three octets" "not an IPv4 address or network" "192.0.2"
refuses "a host name" "not an IPv4 address or network" "client.example"
refuses "an IPv6 address" "not an IPv4 address or network" "2001:db8::1"
refuses "two on one line" "not an IPv4 address or network" "$CLIENT1 $CLIENT3"
refuses "a trailing comment" "not an IPv4 address or network" "$CLIENT1 # box 1"
refuses "an octet with a leading zero" "not an IPv4 address or network" "198.51.100.010"
refuses "a prefix with a leading zero" "not an IPv4 address or network" "198.0.0.0/08"
refuses "a prefix over 32" "not an IPv4 address or network" "198.51.100.0/33"
refuses "host bits set" "host bits set" "198.51.100.1/28"
refuses "every address" "would admit every address" "0.0.0.0/0"
refuses "the same address twice" "overlaps" "$CLIENT1" "$CLIENT1"
refuses "an address inside a listed network" "overlaps" "$CLIENT2" "198.51.100.3"
check "names both lines" said "line 2"

new_case "refused on a first run"
clients "not-an-address"
run_firewall
check "fails" failed
check "names the file and the line" said "$CLIENTS_FILE line 1"
check "writes no ruleset" no_ruleset
check "loads nothing" nothing_loaded

new_case "not root"
echo 1000 >"$STATE/uid"
clients "$CLIENT1"
run_firewall
check "fails" failed
check "says so" said "must run as root"
check "writes no ruleset" no_ruleset

new_case "nft refuses the ruleset"
clients "$CLIENT1"
touch "$STATE/nft-refuses"
run_firewall
check "fails" failed
check "says so" said "nft refused"
check "loads nothing" nothing_loaded

new_case "nft refuses a changed list once"
clients "$CLIENT1" "$CLIENT3"
run_firewall
clients "$CLIENT3"
touch "$STATE/nft-refuses"
run_firewall
check "fails" failed
check "the removed address is still in the loaded table" loaded_has "    elements = { $CLIENT1, $CLIENT3 }"
rm -f "$STATE/nft-refuses"
run_firewall
check "the next run succeeds" succeeded
check "the next run loads the new list" test "$(loads)" -eq 3
check "the removed address is no longer admitted" loaded_lacks "$CLIENT1"

new_case "an unknown command"
run_firewall open
check "fails" failed
check "prints the usage" said "usage:"

# --- status --------------------------------------------------------------------

echo "==> status"

new_case "status with the table loaded"
clients "$CLIENT1" "$CLIENT3"
run_firewall
run_firewall status
check "succeeds" succeeded
check "says the table is loaded" printed "filone_import loaded"
check "names the clients" printed "$CLIENT1 $CLIENT3"
check "changes nothing" test "$(loads)" -eq 1

new_case "status with no clients"
run_firewall
run_firewall status
check "succeeds" succeeded
check "says the port is closed" printed "closed to every address"

new_case "status after an edit not yet applied"
clients "$CLIENT1" "$CLIENT3"
run_firewall
clients "$CLIENT3"
run_firewall status
check "fails" failed
check "names what the loaded table admits" printed "admitted to the import service's port: $CLIENT1 $CLIENT3"
check "does not report the edited list as admitted" eval '! grep -qF "port: $CLIENT3 (" "$CASE/stdout"'
check "says the list has not been applied" printed "has not been applied"
check "loads nothing" test "$(loads)" -eq 1

new_case "status after an edit the script would refuse"
clients "$CLIENT1"
run_firewall
clients "not-an-address"
run_firewall status
check "fails" failed
check "names what the loaded table admits" printed "admitted to the import service's port: $CLIENT1"
check "says why the list is refused" said "$CLIENTS_FILE line 1"

new_case "status with the table gone"
clients "$CLIENT1"
run_firewall
rm -f "$STATE/nft-loaded"
run_firewall status
check "fails" failed
check "says the table is missing" printed "filone_import is missing"
check "loads nothing" test "$(loads)" -eq 1

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
