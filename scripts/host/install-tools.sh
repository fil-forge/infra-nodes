#!/usr/bin/env bash
# Install the identity tooling: ucantool and cast, pinned in the node's
# node.env.
#
# Run by provision-platform.sh, and directly for a version bump: upgrading a
# tool is a new pin merged to this repository and a re-run of this script,
# never a replaced instance. Each binary is fetched from a pinned release and
# checksum-verified, and an installed copy that already matches its pin is
# left alone, so re-runs are cheap and offline-safe.
#
# Only key generation uses these tools. The deploy scripts never call this,
# so the unattended reconcile path gains no dependency on GitHub releases.
set -euo pipefail

# SC2154: the *_VERSION and *_SHA256 pins come from the node's node.env, which
# filone_init sources at run time.
# shellcheck disable=SC2154

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

filone_init

echo "=== install tools ($FILONE_NODE) ==="

case "$(uname -m)" in
  x86_64)        host_platform=linux_amd64 ;;
  aarch64|arm64) host_platform=linux_arm64 ;;
  *) die "unsupported host architecture '$(uname -m)'; expected x86_64 or aarch64" ;;
esac

[ "${TARGET_PLATFORM:-}" = "$host_platform" ] ||
  die "node target platform '${TARGET_PLATFORM:-unset}' does not match host platform '$host_platform'"

echo "  target platform: $TARGET_PLATFORM"

# The pinned checksums cover the release archives, not the extracted binaries,
# so a version-and-platform stamp next to each binary records which pin
# installed it.
#
# Usage: install_from_archive <name> <version> <sha256> <url> <member>
install_from_archive() {
  local name="$1" version="$2" sha256="$3" url="$4" member="$5"
  local stamp="/etc/fil-one/$name.version" expected_stamp="$version $TARGET_PLATFORM"

  if [ -z "$version" ] || [ -z "$sha256" ]; then
    die "no $name pin: set its version and sha256 in nodes/$FILONE_NODE/node.env"
  fi

  if [ -x "/usr/local/bin/$name" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$expected_stamp" ]; then
    echo "  $name already at $expected_stamp"
    return 0
  fi

  local tmp
  tmp="$(mktemp -d)"
  echo "  fetching $name $version"
  curl -fsSL -o "$tmp/archive.tar.gz" "$url"
  echo "$sha256  $tmp/archive.tar.gz" | sha256sum -c -
  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" "$member"
  install -m 0755 "$tmp/$member" "/usr/local/bin/$name"
  printf '%s\n' "$expected_stamp" >"$stamp"
  rm -rf "$tmp"
}

# Only cast. forge, anvil and chisel are a compiler and two test tools that
# this node has no use for.
install_from_archive cast "$FOUNDRY_VERSION" "$FOUNDRY_SHA256" \
  "https://github.com/foundry-rs/foundry/releases/download/$FOUNDRY_VERSION/foundry_${FOUNDRY_VERSION}_${TARGET_PLATFORM}.tar.gz" \
  cast
cast --version

# The release tag carries a leading v; the asset name does not.
install_from_archive ucantool "$UCANTOOL_VERSION" "$UCANTOOL_SHA256" \
  "https://github.com/fil-forge/ucantool/releases/download/$UCANTOOL_VERSION/ucantool_${UCANTOOL_VERSION#v}_${TARGET_PLATFORM}.tar.gz" \
  ucantool
ucantool --help >/dev/null

echo "=== tools installed ==="
