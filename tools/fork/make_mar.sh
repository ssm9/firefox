#!/bin/bash
# Build a signed complete MAR for one target from an already-packaged objdir.
#
# Usage: make_mar.sh <target> <objdir> <outdir>
#   e.g. make_mar.sh linux64 obj-fork-linux64 artifacts/
#
# Only complete MARs are produced. Partial MARs would halve download size but
# require keeping the previous release's unpacked build around and generating
# a diff per (from, to) pair; not worth the pipeline complexity for a fork.

set -euo pipefail

# Report where an unexpected failure happened. Without this, any command that
# trips `set -e` outside an explicit check kills the script with no output at
# all, which from the build loop is indistinguishable from a signing error.
trap 'echo "ERROR: make_mar.sh line $LINENO failed: $BASH_COMMAND" >&2' ERR

TARGET="${1:?usage: make_mar.sh <target> <objdir> <outdir>}"
OBJDIR="${2:?usage: make_mar.sh <target> <objdir> <outdir>}"
OUTDIR="${3:?usage: make_mar.sh <target> <objdir> <outdir>}"

cd "$(dirname "$0")"
. ./config.sh
TOPSRCDIR="$(git rev-parse --show-toplevel)"
cd "$TOPSRCDIR"

OBJDIR="$(cd "$OBJDIR" && pwd)"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

# `mach package` leaves the unpacked application here.
case "$TARGET" in
  linux64) APPDIR="$OBJDIR/dist/firefox" ;;
  win64)   APPDIR="$OBJDIR/dist/firefox" ;;
  *) echo "unknown target: $TARGET" >&2; exit 1 ;;
esac

if [ ! -d "$APPDIR" ]; then
  echo "ERROR: $APPDIR does not exist. Run './mach package' first." >&2
  exit 1
fi

# Read straight from the packaged application, which the check above has
# already confirmed exists.
#
# The previous version tried $OBJDIR/dist/bin/application.ini first with stderr
# discarded and fell back to this one. Under `set -e` with `pipefail` that
# could never work: a missing file made cat fail, pipefail propagated it, and
# the script exited before reaching the fallback -- silently, because stderr
# was redirected away.
APPINI="$APPDIR/application.ini"
if [ ! -f "$APPINI" ]; then
  echo "ERROR: $APPINI not found." >&2
  exit 1
fi

VERSION="$(sed -n 's/^Version=//p' "$APPINI" | head -1)"
BUILDID="$(sed -n 's/^BuildID=//p' "$APPINI" | head -1)"

if [ -z "$VERSION" ] || [ -z "$BUILDID" ]; then
  echo "ERROR: could not read Version/BuildID from $APPINI" >&2
  exit 1
fi

# mar is a HostProgram and signmar a Program (modules/libmar/tool/moz.build),
# so they land in different places: dist/host/bin and dist/bin respectively.
MAR_BIN="$OBJDIR/dist/host/bin/mar"

# For a cross-compiled target, dist/bin/signmar is built for that target and
# cannot run here -- a win64 build produces a Windows executable. Signing is
# architecture-independent, so FORK_SIGNMAR lets the caller pass a native one
# built for the host.
SIGNMAR_BIN="${FORK_SIGNMAR:-$OBJDIR/dist/bin/signmar}"

if [ ! -x "$MAR_BIN" ]; then
  echo "ERROR: $MAR_BIN not found or not executable." >&2
  exit 1
fi

if [ ! -x "$SIGNMAR_BIN" ]; then
  echo "ERROR: $SIGNMAR_BIN not found or not executable." >&2
  exit 1
fi

# Catch a cross-built signmar before it is used: exec failure reports 126/127,
# which is otherwise easy to mistake for a signing error.
#
# `|| rc=$?` is required. signmar exits non-zero for a usage message, and under
# `set -e` a bare invocation kills the script before the status can be read --
# so this check, meant to produce a clearer error, became one itself.
rc=0
"$SIGNMAR_BIN" -h >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
  echo "ERROR: $SIGNMAR_BIN cannot be executed on this host -- it was probably" >&2
  echo "built for the target. Set FORK_SIGNMAR to a host-native signmar." >&2
  exit 1
fi

UNSIGNED="$OUTDIR/firefox-$VERSION.$TARGET.complete.unsigned.mar"
SIGNED="$OUTDIR/firefox-$VERSION.$TARGET.complete.mar"

echo "Packaging complete MAR for $TARGET ($VERSION / $BUILDID)"
MAR="$MAR_BIN" \
MOZ_PRODUCT_VERSION="$VERSION" \
MAR_CHANNEL_ID="$FORK_MAR_CHANNEL_ID" \
  "$TOPSRCDIR/tools/update-packaging/make_full_update.sh" "$UNSIGNED" "$APPDIR"

echo "Signing MAR"
NSS_DB="${FORK_NSS_DIR}"
if [ ! -d "$NSS_DB" ]; then
  echo "ERROR: NSS database $NSS_DB not found. Run gen_mar_key.sh, or" >&2
  echo "restore it from the FORK_MAR_NSS_DB secret." >&2
  exit 1
fi

"$SIGNMAR_BIN" -d "$NSS_DB" -n "$FORK_MAR_CERT_NICKNAME" -s "$UNSIGNED" "$SIGNED"
rm -f "$UNSIGNED"

# Verify against the same certificate that is compiled into the updater. If
# this fails, shipping the MAR would produce builds that reject their own
# updates.
#
# signmar's -D DERFilePath form does not exist here. It is compiled out
# whenever MAR_NSS is defined, and MOZ_USE_NSS_FOR_MAR is unconditionally true
# on Linux -- --enable-nss-mar can only be toggled on Windows and macOS
# (build/moz.configure/update-programs.configure:131). Verification therefore
# has to go through an NSS database.
#
# The certificate is imported into a throwaway database rather than verifying
# against the signing database directly: the point of this check is that the
# MAR validates against the exact bytes that get compiled into the updater, and
# verifying against the key that just signed it would prove nothing.
#
# The ",," trust flags are deliberate and sufficient. signmar looks the
# certificate up by nickname, then passes its raw DER straight to
# mar_verify_signatures (modules/libmar/tool/mar.c:379) -- the same function
# the updater calls -- so trust is never evaluated and this reproduces the
# check an installed build performs.
echo "Verifying signature against the committed certificate"

CERT_DER="$TOPSRCDIR/toolkit/mozapps/update/updater/release_primary.der"
if [ ! -s "$CERT_DER" ]; then
  echo "ERROR: $CERT_DER is missing or empty." >&2
  exit 1
fi

VERIFY_DB="$(mktemp -d)"
VERIFY_PW="$(mktemp)"
trap 'rm -rf "$VERIFY_DB" "$VERIFY_PW"' EXIT
printf '\n' > "$VERIFY_PW"

certutil -N -d "$VERIFY_DB" -f "$VERIFY_PW"
certutil -A -d "$VERIFY_DB" -f "$VERIFY_PW" -n forkverify -t ",," -i "$CERT_DER"
"$SIGNMAR_BIN" -d "$VERIFY_DB" -n forkverify -v "$SIGNED"

SIZE="$(wc -c < "$SIGNED" | tr -d ' ')"
HASH="$(openssl dgst -sha512 "$SIGNED" | awk '{print $NF}')"

cat > "$OUTDIR/$TARGET.mar.json" <<EOF
{
  "target": "$TARGET",
  "version": "$VERSION",
  "buildID": "$BUILDID",
  "file": "$(basename "$SIGNED")",
  "size": $SIZE,
  "hashFunction": "SHA512",
  "hashValue": "$HASH"
}
EOF

echo "Wrote $SIGNED"
echo "Wrote $OUTDIR/$TARGET.mar.json"
