#!/bin/bash
# Install a fork build on Linux, with launcher integration.
#
# Usage: install-linux.sh [tarball] [install-dir]
#   e.g. install-linux.sh firefox-153.0.1.en-US.linux-x86_64.tar.xz
#
# Deliberately not a .deb or .rpm. Those install root-owned under /usr/lib,
# where Firefox's updater -- running as you -- cannot write, so every update
# downloads and then silently fails to apply. Mozilla's own .deb works around
# that by disabling the internal updater and shipping updates through their APT
# repository instead; matching that would mean running a signed package repo
# alongside the MAR server and leaving the MAR pipeline unused.
#
# Extracting to a user-writable location keeps auto-update working, and the
# .desktop entry written here is what the package manager was wanted for.

set -euo pipefail

trap 'echo "ERROR: install-linux.sh line $LINENO failed: $BASH_COMMAND" >&2' ERR

TARBALL="${1:-}"
PREFIX="${2:-$HOME/.local/opt}"

APP_NAME="Firefox (onDeterminingFilename fork)"
APP_ID="firefox-ssm9"
INSTALL_DIR="$PREFIX/$APP_ID"

if [ -z "$TARBALL" ]; then
  echo "usage: install-linux.sh <tarball> [install-dir]" >&2
  echo "  e.g. install-linux.sh firefox-153.0.1.en-US.linux-x86_64.tar.xz" >&2
  exit 1
fi

if [ ! -f "$TARBALL" ]; then
  echo "ERROR: $TARBALL not found." >&2
  exit 1
fi

# A root-owned install directory would leave the updater unable to write, which
# is the whole failure mode this script exists to avoid.
mkdir -p "$PREFIX"
if [ ! -w "$PREFIX" ]; then
  echo "ERROR: $PREFIX is not writable by $(id -un)." >&2
  echo "Choose a location you own, or updates will never apply." >&2
  exit 1
fi

if [ -d "$INSTALL_DIR" ]; then
  echo "Removing the previous install at $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
fi

echo "Extracting to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
# The tarball contains a top-level firefox/ directory; strip it so the binary
# lands directly in INSTALL_DIR.
tar -xf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1

if [ ! -x "$INSTALL_DIR/firefox" ]; then
  echo "ERROR: no firefox binary in $INSTALL_DIR after extraction." >&2
  exit 1
fi

# Launcher entry. A distinct APP_ID and StartupWMClass keep this separate from
# any system Firefox rather than replacing it in the launcher.
DESKTOP_DIR="$HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_DIR/$APP_ID.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$APP_NAME
GenericName=Web Browser
Comment=Firefox with downloads.onDeterminingFilename
Exec=$INSTALL_DIR/firefox %u
Icon=$APP_ID
Terminal=false
StartupNotify=true
StartupWMClass=firefox
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
EOF

# Icons, so the launcher entry is not a generic placeholder.
for size in 16 32 48 64 128; do
  src="$INSTALL_DIR/browser/chrome/icons/default/default$size.png"
  if [ -f "$src" ]; then
    dest="$HOME/.local/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$dest"
    cp -f "$src" "$dest/$APP_ID.png"
  fi
done

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo
echo "Installed to $INSTALL_DIR"
echo "Launcher entry: $DESKTOP_DIR/$APP_ID.desktop"
echo
echo "Run it with: $INSTALL_DIR/firefox"
echo
echo "To load an unsigned extension, set xpinstall.signatures.required to false"
echo "in about:config. Check for updates under About; the build points at the"
echo "fork update server and applies them in place."
