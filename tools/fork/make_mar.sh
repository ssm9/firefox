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

VERSION="$(cat "$OBJDIR/dist/bin/application.ini" 2>/dev/null \
  | sed -n 's/^Version=//p' | head -1)"
if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/^Version=//p' "$APPDIR/application.ini" | head -1)"
fi
BUILDID="$(sed -n 's/^BuildID=//p' "$APPDIR/application.ini" | head -1)"

if [ -z "$VERSION" ] || [ -z "$BUILDID" ]; then
  echo "ERROR: could not read Version/BuildID from application.ini" >&2
  exit 1
fi

MAR_BIN="$OBJDIR/dist/host/bin/mar"
SIGNMAR_BIN="$OBJDIR/dist/host/bin/signmar"
for bin in "$MAR_BIN" "$SIGNMAR_BIN"; do
  if [ ! -x "$bin" ]; then
    echo "ERROR: $bin not found or not executable." >&2
    exit 1
  fi
done

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

# Verify against the same DER that is compiled into the updater. If this fails,
# shipping the MAR would produce builds that reject their own updates.
echo "Verifying signature against the committed certificate"
"$SIGNMAR_BIN" -D "$TOPSRCDIR/toolkit/mozapps/update/updater/release_primary.der" \
  -v "$SIGNED"

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
