#!/bin/bash
# Install a fork build on macOS. Run this on the Mac, not on the build server.
#
# Usage: install-macos.sh [tarball] [install-dir]
#   e.g. install-macos.sh firefox-153.0.1.en-US.mac-aarch64.tar.gz
#
# Installs under ~/Applications rather than /Applications. The updater runs as
# the invoking user and elevates only when the install directory is not
# writable by it (toolkit/xre/nsUpdateDriver.cpp:451); an install under
# /Applications owned by anyone else would therefore prompt for an
# administrator password on every single update. Elevation on macOS also goes
# through a privileged helper that checks the caller against a code signing
# requirement, which an unsigned fork build cannot satisfy.
#
# These builds carry no Developer ID signature and are not notarized. The
# individual binaries are ad-hoc signed by the linker, which is what Apple
# Silicon requires to execute them at all, but the bundle as a whole is
# unsigned, so Gatekeeper blocks it while the quarantine flag is set. This
# script clears that flag, which is the same thing `xattr -dr` does by hand.

set -euo pipefail

trap 'echo "ERROR: install-macos.sh line $LINENO failed: $BASH_COMMAND" >&2' ERR

TARBALL="${1:-}"
PREFIX="${2:-$HOME/Applications}"

if [ -z "$TARBALL" ]; then
  echo "usage: install-macos.sh <tarball> [install-dir]" >&2
  echo "  e.g. install-macos.sh firefox-153.0.1.en-US.mac-aarch64.tar.gz" >&2
  exit 1
fi

if [ ! -f "$TARBALL" ]; then
  echo "ERROR: $TARBALL not found." >&2
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this installs a macOS build; run it on the Mac." >&2
  exit 1
fi

# A single-architecture arm64 build. Rosetta translates x86_64 to arm64, never
# the other way round, so there is nothing an Intel Mac can do with this.
if [ "$(uname -m)" != "arm64" ]; then
  echo "ERROR: this build is for Apple Silicon, and this Mac is $(uname -m)." >&2
  exit 1
fi

mkdir -p "$PREFIX"
if [ ! -w "$PREFIX" ]; then
  echo "ERROR: $PREFIX is not writable by $(id -un)." >&2
  echo "Choose a location you own, or every update will ask for a password." >&2
  exit 1
fi

# Unpacked next to the destination rather than in /tmp: /tmp is often a
# different filesystem, which would turn the move below into a slow copy.
STAGING="$(mktemp -d "$PREFIX/.firefox-fork-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

echo "Unpacking $TARBALL"
# The archive holds a single firefox/ directory containing the bundle.
tar -xf "$TARBALL" -C "$STAGING"

shopt -s nullglob
BUNDLES=("$STAGING"/firefox/*.app)
shopt -u nullglob
if [ "${#BUNDLES[@]}" -ne 1 ]; then
  echo "ERROR: expected one .app in the archive, found ${#BUNDLES[@]}." >&2
  exit 1
fi

APP_NAME="$(basename "${BUNDLES[0]}")"
INSTALL_DIR="$PREFIX/$APP_NAME"

if [ -d "$INSTALL_DIR" ]; then
  echo "Removing the previous install at $INSTALL_DIR"
  # A replace rather than a merge. Leaving the old bundle in place would keep
  # files this release has dropped, and the updater's own bookkeeping assumes
  # the bundle matches the manifest it was packaged from.
  rm -rf "$INSTALL_DIR"
fi

mv "${BUNDLES[0]}" "$INSTALL_DIR"

# Downloading through a browser marks the archive, and everything unpacked from
# it, with com.apple.quarantine. Launching a quarantined bundle that carries no
# Developer ID signature gets refused outright, usually reported as the
# application being damaged.
if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$INSTALL_DIR" 2>/dev/null || true
fi

# Registering the bundle means Finder and `open -a` find it immediately rather
# than whenever Launch Services next rescans.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$INSTALL_DIR" >/dev/null 2>&1 || true
fi

echo
echo "Installed to $INSTALL_DIR"
echo
echo "Run it with: open '$INSTALL_DIR'"
echo
echo "To load an unsigned extension, set xpinstall.signatures.required to false"
echo "in about:config. Check for updates under About; the build points at the"
echo "fork update server and applies them in place."
