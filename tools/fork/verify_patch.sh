#!/bin/bash
# Verify that the onDeterminingFilename patch series actually reached a build.
#
# Usage: verify_patch.sh <objdir-or-omni.ja> [srcdir]
#   e.g. verify_patch.sh /src/firefox/obj-x86_64-pc-linux-gnu
#        verify_patch.sh /path/to/omni.ja
#
# Every patched file is plain JS or JSON that ships verbatim inside the GRE
# omni.ja -- none of it is preprocessed or minified -- so the shipped copy can
# be compared byte-for-byte against the source it was built from. That is a
# stronger check than grepping for a marker: it catches a stale omni.ja, a
# partial repack, or a jar.mn entry that silently failed to package a file.
#
# The byte comparison is only meaningful when srcdir is the tree the build came
# from. Pointed at a checkout of a different revision, every file legitimately
# DIFFERS and the result says nothing. The two checks at the end do not depend
# on srcdir and are valid against any build.

set -uo pipefail

TARGET="${1:?usage: verify_patch.sh <objdir-or-omni.ja> [srcdir]}"
SRCDIR="${2:-}"

if [ -d "$TARGET" ]; then
  OMNI="$TARGET/dist/firefox/omni.ja"
else
  OMNI="$TARGET"
fi

if [ ! -f "$OMNI" ]; then
  echo "ERROR: no omni.ja at $OMNI" >&2
  exit 2
fi

if [ -z "$SRCDIR" ]; then
  # Not derived from this script's location: the build server keeps its tooling
  # in a separate checkout, so ../.. is the tooling repository rather than the
  # Firefox tree the build came from.
  SRCDIR="${FORK_SRCDIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
fi

if [ ! -d "$SRCDIR/toolkit/components/downloads" ]; then
  echo "ERROR: $SRCDIR does not look like a Firefox checkout." >&2
  echo "Pass it as the second argument, or set FORK_SRCDIR." >&2
  exit 2
fi

# source path : path inside omni.ja
FILES="
toolkit/components/downloads/DownloadCore.sys.mjs:modules/DownloadCore.sys.mjs
toolkit/components/downloads/DownloadIntegration.sys.mjs:modules/DownloadIntegration.sys.mjs
toolkit/components/downloads/DownloadLegacy.sys.mjs:modules/DownloadLegacy.sys.mjs
toolkit/mozapps/downloads/HelperAppDlg.sys.mjs:modules/HelperAppDlg.sys.mjs
toolkit/components/extensions/parent/ext-downloads.js:chrome/toolkit/content/extensions/parent/ext-downloads.js
toolkit/components/extensions/child/ext-downloads.js:chrome/toolkit/content/extensions/child/ext-downloads.js
toolkit/components/extensions/child/ext-toolkit.js:chrome/toolkit/content/extensions/child/ext-toolkit.js
toolkit/components/extensions/schemas/downloads.json:chrome/toolkit/content/extensions/schemas/downloads.json
"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
missing=0
mismatch=0

echo "omni.ja: $OMNI"
echo "source:  $SRCDIR"
echo

for pair in $FILES; do
  src="${pair%%:*}"
  jar="${pair#*:}"

  if ! unzip -p "$OMNI" "$jar" > "$TMP/shipped" 2>/dev/null || [ ! -s "$TMP/shipped" ]; then
    printf 'MISSING   %s\n' "$jar"
    missing=$((missing + 1))
    fail=1
    continue
  fi

  if [ ! -f "$SRCDIR/$src" ]; then
    printf 'NO SOURCE %s\n' "$src"
    fail=1
    continue
  fi

  if cmp -s "$TMP/shipped" "$SRCDIR/$src"; then
    printf 'ok        %s\n' "$jar"
  else
    printf 'DIFFERS   %s\n' "$jar"
    mismatch=$((mismatch + 1))
    fail=1
  fi
done

echo

# The child module is the single clearest signal: it does not exist at all in
# an unpatched Firefox, so its presence cannot be explained by anything else.
if unzip -l "$OMNI" chrome/toolkit/content/extensions/child/ext-downloads.js \
    > /dev/null 2>&1; then
  echo "child/ext-downloads.js is present (does not exist in stock Firefox)"
else
  echo "child/ext-downloads.js is ABSENT -- this build is not patched"
  fail=1
fi

# And the API has to be declared in the schema, or nothing can call it.
if unzip -p "$OMNI" chrome/toolkit/content/extensions/schemas/downloads.json \
    2>/dev/null | grep -q "onDeterminingFilename"; then
  echo "downloads.json declares onDeterminingFilename"
else
  echo "downloads.json does NOT declare onDeterminingFilename"
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: all 8 patched files shipped and match their source"
else
  echo "FAIL: $missing missing, $mismatch differing"
  echo
  echo "A DIFFERS result usually means the omni.ja predates the current"
  echo "checkout -- rebuild rather than assuming the patch is wrong."
fi
exit "$fail"
