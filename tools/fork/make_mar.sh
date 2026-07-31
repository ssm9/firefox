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

# The Firefox source tree, which is not necessarily this script's repository:
# the build server keeps its tooling in a separate checkout so the Firefox tree
# can be a pure release-tag checkout. Deriving it from $0 would find the tooling
# repository and then fail looking for tools/update-packaging in it.
TOPSRCDIR="${FORK_SRCDIR:-$(git rev-parse --show-toplevel)}"
if [ ! -f "$TOPSRCDIR/tools/update-packaging/make_full_update.sh" ]; then
  echo "ERROR: $TOPSRCDIR does not look like a Firefox checkout." >&2
  echo "Set FORK_SRCDIR to the source tree the build came from." >&2
  exit 1
fi
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

# Confirm the updater being shipped actually trusts the key this MAR will be
# signed with.
#
# toolkit/mozapps/update/updater/gen_cert_header.py turns release_primary.der
# into a `const uint8_t[]`, so the certificate's bytes appear verbatim in the
# compiled binary and can be searched for directly.
#
# This matters because the failure is otherwise invisible until too late: a MAR
# whose updater embeds a different certificate installs perfectly, and then
# rejects every subsequent update. The build would look fine and break one
# release later, on machines already in the field.
CERT_DER="$FORK_NSS_DIR/release_primary.der"
if [ ! -s "$CERT_DER" ]; then
  echo "ERROR: $CERT_DER is missing or empty." >&2
  exit 1
fi

UPDATER_BIN="$APPDIR/updater"
if [ -f "$UPDATER_BIN" ]; then
  if python3 - "$CERT_DER" "$UPDATER_BIN" <<'PY'
import sys
der = open(sys.argv[1], "rb").read()
blob = open(sys.argv[2], "rb").read()
sys.exit(0 if der in blob else 1)
PY
  then
    echo "Updater embeds the fork certificate"
  else
    echo "ERROR: $UPDATER_BIN does not embed $CERT_DER." >&2
    echo "It was built before install_mar_cert ran, so it trusts a different" >&2
    echo "certificate. Publishing this would install fine and then reject every" >&2
    echo "later update. Rebuild with the certificate in place." >&2
    exit 1
  fi
else
  echo "WARNING: no updater at $UPDATER_BIN; cannot confirm which certificate" >&2
  echo "this build trusts." >&2
fi

# mar is a HostProgram and signmar a Program (modules/libmar/tool/moz.build),
# so they land in different places: dist/host/bin and dist/bin respectively.
MAR_BIN="$OBJDIR/dist/host/bin/mar"

if [ ! -x "$MAR_BIN" ]; then
  echo "ERROR: $MAR_BIN not found or not executable." >&2
  exit 1
fi

# Whether a binary can actually run on this host. A cross-compiled signmar is
# built for its target -- win64's is a Windows executable -- and exec failure
# reports 126 or 127, which is otherwise easy to mistake for a signing error.
#
# `|| rc=$?` is required: signmar exits non-zero for a usage message, and under
# `set -e` a bare invocation would kill the script before the status is read.
signmar_runs_here() {
  [ -x "$1" ] || return 1
  local rc=0
  "$1" -h >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ]
}

# Signing is architecture-independent, so any host-native signmar will do.
# Preference order: one the caller named, this target's own, then any sibling
# object directory's.
#
# The search matters because targets build concurrently. Relying on the caller
# to pass one assumes the native build finished first, which the pipeline does
# not guarantee -- win64 can reach packaging while linux64 is still compiling.
SIGNMAR_BIN=""
for candidate in "${FORK_SIGNMAR:-}" "$OBJDIR/dist/bin/signmar"; do
  if [ -n "$candidate" ] && signmar_runs_here "$candidate"; then
    SIGNMAR_BIN="$candidate"
    break
  fi
done

if [ -z "$SIGNMAR_BIN" ]; then
  for candidate in "$(dirname "$OBJDIR")"/*/dist/bin/signmar; do
    if signmar_runs_here "$candidate"; then
      SIGNMAR_BIN="$candidate"
      echo "Using signmar from $candidate (this target's is not host-native)"
      break
    fi
  done
fi

if [ -z "$SIGNMAR_BIN" ]; then
  echo "ERROR: no signmar that runs on this host." >&2
  echo "Searched $OBJDIR and its sibling object directories. A cross-compiled" >&2
  echo "target builds signmar for the target, so a native build must have" >&2
  echo "completed first, or FORK_SIGNMAR must name one." >&2
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

# CERT_DER is the copy on the state volume, resolved above. Deliberately not
# the one in the source tree: install_mar_cert copies the former over the
# latter before every build, so the state volume is the authoritative source of
# what gets compiled in, while the tree copy is transient -- any
# `git checkout -f` reverts it to upstream's, and the loop does exactly that at
# the start of each cycle.

# If the tree disagrees, the build may have been made with a different
# certificate. Not fatal on its own: it also happens whenever the tree is
# re-checked-out after a build, which is routine.
TREE_DER="$TOPSRCDIR/toolkit/mozapps/update/updater/release_primary.der"
if [ -s "$TREE_DER" ] && ! cmp -s "$CERT_DER" "$TREE_DER"; then
  echo "WARNING: $TREE_DER differs from $CERT_DER." >&2
  echo "If this build was produced without install_mar_cert running first," >&2
  echo "it trusts a different certificate and will reject these updates." >&2
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
