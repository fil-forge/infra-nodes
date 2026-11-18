#!/usr/bin/env bash
# The host firewall in front of the import service's port.
#
#   import-firewall.sh           apply the client list in /etc/fil-one/import-clients
#   import-firewall.sh status    say what the loaded table admits, and fail when the
#                                table is gone or the list has changed since it loaded
#
# The import service publishes its port through Docker, and UFW does not filter
# a port Docker publishes. So the rule is an nftables table of the node's own,
# filone_import, with one chain on the forward hook ahead of Docker's filter
# chains: it drops every packet of a connection Docker's port publishing
# translated to the service's port, unless the connection comes from an address
# on the list. A drop there is final. An empty list, or no file at all, drops
# them all, and the script says that the port is closed to every address.
#
# The list is a provisioning-time input kept on the host, because this
# repository is public. One entry per line: an IPv4 address, or a network as
# address/prefix with no host bits set. Blank lines and lines starting with #
# are ignored; anything else on a line is refused, as is an entry that overlaps
# another and 0.0.0.0/0, which would admit every address. A refused list
# changes nothing: the table already loaded stays as it is.
#
# The table is replaced whole, in one atomic load, so an address taken off the
# list loses its access, open connections included, in the same step as a new
# one gains it. A run whose list matches the loaded table loads nothing. Docker
# and UFW never flush this table, and nothing here adds to, reorders or reads
# their chains, or any other table.
#
# deploy-import.sh applies the list before it starts the service, on every run.
# A reboot empties the table, and the service cannot start until that deploy
# has rendered its certificates into the secrets tmpfs, so the port is never
# open without the table in front of it. After editing the list, run this as
# root, then `import-firewall.sh status`.
#
# Files under /etc and /run are read only through cat and cmp and written only
# through install and rm, which is what lets the test in tests/ run it against
# stubs.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

CLIENTS_FILE=/etc/fil-one/import-clients
NFT_RULESET=/run/fil-one/import-nftables.conf
NFT_TABLE=filone_import
# The port the service listens on inside its container, which
# nodes/<node>/apps/compose.yml publishes. Matched after Docker's translation,
# so the host port node.env chooses does not matter here.
SERVICE_PORT=8443

usage() { die "usage: $(basename "$0") [status]"; }

# --- Addresses -------------------------------------------------------------
# As in setup-vpn.sh, except that an octet or prefix with a leading zero is
# refused: nft reads an address through inet_aton, which takes 010 as octal 8,
# so the table would admit an address other than the one on the list.

ipv4_to_int() { # prints the address as a number, or fails
  local IFS=. a b c d octet
  [[ "$1" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
  read -r a b c d <<<"$1"
  for octet in "$a" "$b" "$c" "$d"; do
    [ "$((10#$octet))" -le 255 ] || return 1
  done
  echo $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

# The first and last address an entry covers, as two numbers.
entry_range() { # entry_range <address[/prefix]>
  local start prefix=32 mask
  case "$1" in */*) prefix="${1#*/}" ;; esac
  start="$(ipv4_to_int "${1%/*}")"
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  echo "$((start & mask)) $(((start & mask) | (~mask & 0xFFFFFFFF)))"
}

# Why an entry is refused, or nothing when it is a valid address or network.
entry_problem() { # entry_problem <entry>
  local address="${1%/*}" prefix=32 start mask
  if [[ "$1" == */* ]]; then
    prefix="${1#*/}"
    [[ "$prefix" =~ ^(0|[1-9][0-9]?)$ ]] && [ "$prefix" -le 32 ] || {
      echo "is not an IPv4 address or network"
      return
    }
  fi
  start="$(ipv4_to_int "$address")" || {
    echo "is not an IPv4 address or network"
    return
  }
  [ "$prefix" -gt 0 ] || {
    echo "would admit every address"
    return
  }
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  [ $((start & mask)) -eq "$start" ] || echo "has host bits set"
}

# --- The list --------------------------------------------------------------

# Read and check the list into CLIENTS, space-separated, in file order. Dies on
# the first refused line, naming it.
load_clients() {
  local content line entry number=0 problem i
  local entries=() lines=() ranges=() range low high other_low other_high
  CLIENTS=""
  # No file is an empty list, which closes the port.
  content="$(cat "$CLIENTS_FILE" 2>/dev/null)" || content=""
  while IFS= read -r line; do
    number=$((number + 1))
    # Surrounding blanks are not part of the entry.
    entry="${line#"${line%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    case "$entry" in '' | '#'*) continue ;; esac
    problem="$(entry_problem "$entry")"
    [ -z "$problem" ] || die "$CLIENTS_FILE line $number: '$entry' $problem"
    range="$(entry_range "$entry")"
    low="${range% *}"
    high="${range#* }"
    i=0
    while [ "$i" -lt "${#entries[@]}" ]; do
      other_low="${ranges[$i]% *}"
      other_high="${ranges[$i]#* }"
      if [ "$low" -le "$other_high" ] && [ "$other_low" -le "$high" ]; then
        die "$CLIENTS_FILE line $number: '$entry' overlaps '${entries[$i]}' on line ${lines[$i]}"
      fi
      i=$((i + 1))
    done
    entries+=("$entry")
    lines+=("$number")
    ranges+=("$range")
  done <<<"$content"
  CLIENTS="${entries[*]:-}"
}

# --- The table -------------------------------------------------------------

nft_ruleset() {
  cat <<NFT
# Written by scripts/host/import-firewall.sh from $CLIENTS_FILE.
# Replaced whole on every change.
table ip $NFT_TABLE
delete table ip $NFT_TABLE
table ip $NFT_TABLE {
  set clients {
    type ipv4_addr
    flags interval
NFT
  [ -z "$CLIENTS" ] || echo "    elements = { ${CLIENTS// /, } }"
  cat <<NFT
  }

  # Ahead of Docker's filter chains, so a drop here is final. Only connections
  # Docker translated to the service's port, matched in the direction the
  # client opened them, so the service's answers are never dropped.
  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    ct direction original ct status dnat tcp dport $SERVICE_PORT ip saddr != @clients drop
  }
}
NFT
}

# Install stdin at a path, root-only, unless the path already holds exactly
# that; returns 1 when it did not write. As setup-vpn.sh's.
install_if_changed() { # install_if_changed <destination>
  local destination="$1" tmp
  tmp="$(umask 077 && mktemp "${TMPDIR:-$FILONE_SECRETS_DIR}/.import-firewall.XXXXXX")" ||
    die "mktemp failed"
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    die "could not write $tmp"
  fi
  if cmp -s "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi
  if ! install -m 0600 -o root -g root "$tmp" "$destination"; then
    rm -f "$tmp"
    die "could not write $destination"
  fi
  rm -f "$tmp"
}

table_loaded() { nft list table ip "$NFT_TABLE" >/dev/null 2>&1; }

describe_clients() { # describe_clients <space-separated clients>
  if [ -z "$1" ]; then
    echo "the client list is empty: the import service's port is closed to every address"
  else
    echo "admitted to the import service's port: $1"
  fi
}

apply() {
  local changed=0
  load_clients
  install -d -m 0700 -o root -g root /run/fil-one "$FILONE_SECRETS_DIR"
  nft_ruleset | install_if_changed "$NFT_RULESET" && changed=1
  if [ "$changed" = 1 ] || ! table_loaded; then
    echo "  loading nftables table $NFT_TABLE"
    # The file on disk has to match the loaded table, or the next run would
    # find nothing changed and load nothing. Removing it makes that run load.
    if ! nft -f "$NFT_RULESET"; then
      rm -f "$NFT_RULESET"
      die "nft refused the ruleset; the table loaded before stays as it was"
    fi
  else
    echo "  nftables table $NFT_TABLE unchanged"
  fi
  # On stderr when nothing is admitted, so it shows in the journal as well.
  if [ -z "$CLIENTS" ]; then
    describe_clients "" >&2
  else
    echo "  $(describe_clients "$CLIENTS")"
  fi
}

# What the loaded table admits is read from the ruleset file, which apply keeps
# equal to the last load that succeeded. The list is then checked against it,
# so an edit not yet applied is reported as such and not as admitted.
status() {
  local ruleset loaded
  if table_loaded; then
    echo "nftables table $NFT_TABLE loaded"
  else
    echo "nftables table $NFT_TABLE is missing: while the service runs, its port admits every address."
    echo "Run $(basename "$0") as root to load it."
    return 1
  fi
  if ! ruleset="$(cat "$NFT_RULESET" 2>/dev/null)"; then
    echo "$NFT_RULESET is missing, so which addresses the table admits is unknown."
    echo "Run $(basename "$0") as root to load the list again."
    return 1
  fi
  loaded="$(sed -n 's/^    elements = { \(.*\) }$/\1/p' <<<"$ruleset")"
  describe_clients "${loaded//, / }"
  if [ "$( (load_clients && nft_ruleset) 2>/dev/null)" != "$ruleset" ]; then
    # Again, for the reason a refused list gives.
    (load_clients) || true
    echo "$CLIENTS_FILE has changed and has not been applied. Run $(basename "$0") as root to apply it."
    return 1
  fi
}

[ "$(id -u)" -eq 0 ] || die "must run as root"
case "${1:-apply}" in
  apply) apply ;;
  status) status ;;
  *) usage ;;
esac
