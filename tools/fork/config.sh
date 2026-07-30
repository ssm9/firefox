#!/bin/bash
# Shared configuration for the fork build pipeline.
# Sourced by the other scripts in this directory.

# Update channel and MAR channel ID. Must match the values in
# browser/config/mozconfigs/*/fork.
export FORK_CHANNEL=ssm9
export FORK_MAR_CHANNEL_ID=ssm9

# Hostname nginx-proxy-manager serves this under, reached over WireGuard.
#
# This is compiled into every build via build/application.ini.in, so an install
# permanently asks the host it was built with. Pick a name that will not
# change, and make sure it resolves for WireGuard clients -- a name that only
# resolves on the LAN means updates stop working the moment you leave.
#
# build-loop.sh cross-checks both of these against application.ini.in and
# refuses to build if they disagree.
export FORK_UPDATE_SCHEME="${FORK_UPDATE_SCHEME:-http}"
export FORK_UPDATE_HOST="${FORK_UPDATE_HOST:-CHANGEME.lan}"

export FORK_UPDATE_BASE_URL="${FORK_UPDATE_SCHEME}://${FORK_UPDATE_HOST}/updates"
export FORK_DOWNLOAD_BASE_URL="${FORK_UPDATE_SCHEME}://${FORK_UPDATE_HOST}/downloads"

# NSS database holding the MAR signing key, and the nickname of the cert
# within it. The database itself is never committed; see README.md.
export FORK_NSS_DIR="${FORK_NSS_DIR:-$HOME/.ssm9-mar-nss}"
export FORK_MAR_CERT_NICKNAME=ssm9-mar

# Targets built by the pipeline. macOS is deliberately absent; see README.md.
export FORK_TARGETS="linux64 win64"

# Maps a target to the BUILD_TARGET strings Firefox may send in its update URL.
# BUILD_TARGET is `appinfo.OS + "_" + ABI` (toolkit/modules/UpdateUtils.sys.mjs:90).
# On Windows the ABI has the *running* CPU architecture appended
# (UpdateUtils.sys.mjs:1062), so one win64 build reports a different string
# depending on the hardware it lands on. A manifest must be published at every
# path a real install can ask for, or that install silently never updates.
fork_build_targets() {
  case "$1" in
    linux64) echo "Linux_x86_64-gcc3" ;;
    # x64 hardware, and ARM64 hardware running the x64 build under emulation.
    win64)   echo "WINNT_x86_64-msvc-x64 WINNT_x86_64-msvc-aarch64" ;;
    *) echo "unknown target: $1" >&2; return 1 ;;
  esac
}
