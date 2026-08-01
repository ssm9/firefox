#!/bin/bash
# Exercise the patch-application logic against synthetic upstream changes.
#
# Usage: test_apply.sh [workdir]
#
# Needs nothing but git: no container, no Firefox checkout, no network. Run it
# after touching apply_patch_onto or build_fork_commit -- the alternative is
# finding out on a major release, months apart, when the pipeline stops.
#
# The functions under test are extracted from docker/build-loop.sh rather than
# copied here, so this cannot drift from what actually runs on the server.
#
# The case that motivated it: upstream renaming a file the series edits. The
# previous implementation applied a squashed diff with `git apply --3way`,
# which matches patches to files by path and has no rename detection, so it
# failed with "<path>: does not exist in index" -- and rolled the whole apply
# back, leaving no conflict markers to diagnose from.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOOP="${LOOP:-$HERE/docker/build-loop.sh}"
ROOT="${1:-$(mktemp -d)}/fork-apply-test"

if [ ! -f "$LOOP" ]; then
  echo "ERROR: no build-loop.sh at $LOOP" >&2
  exit 1
fi

rm -rf "$ROOT"; mkdir -p "$ROOT"
FUNCS="$ROOT/funcs.sh"
sed -n '/^patch_base() {/,/^}/p;/^build_fork_commit() {/,/^}/p;/^apply_patch_onto() {/,/^}/p' \
  "$LOOP" > "$FUNCS"

for fn in patch_base build_fork_commit apply_patch_onto; do
  grep -q "^$fn() {" "$FUNCS" || {
    echo "ERROR: could not extract $fn from $LOOP" >&2
    exit 1
  }
done

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# Stand-ins for the parts of build-loop.sh the extracted functions call.
log() { echo "    | $*"; }
die() { echo "    | FATAL: $*"; return 1; }
FORK_BRANCH=fork-build

# Build a repository shaped like the real one: an upstream release tag, a fork
# branch carrying both product changes and tooling, and a base they share.
#
# $1 is how upstream diverges: rename, conflict, delete or clean.
setup_repo() {
  local mode="$1"
  rm -rf "$ROOT/repo" "$ROOT/state"
  mkdir -p "$ROOT/repo" "$ROOT/state"
  cd "$ROOT/repo" || exit 1

  git init -q .
  git config user.email fork@test; git config user.name fork
  git config merge.renameLimit 20000
  git config diff.renameLimit 20000

  mkdir -p toolkit/components/downloads tools/fork .woodpecker
  seq 1 40 > toolkit/components/downloads/DownloadIntegration.sys.mjs
  seq 1 40 > toolkit/components/extensions.js
  git add -A; git commit -qm base
  BASE="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main HEAD

  # The fork edits a file, adds a file, and carries tooling that must never
  # reach the build tree.
  git checkout -qb "$FORK_BRANCH"
  perl -pi -e 's/^20$/20 FORK EDIT/' \
    toolkit/components/downloads/DownloadIntegration.sys.mjs
  echo "fork test file" > toolkit/components/test_determining_filename.js
  echo "tooling, must not land" > tools/fork/config.sh
  echo "pipeline, must not land" > .woodpecker/firefox-fork.yaml
  git add -A; git commit -qm "fork: the series"
  git update-ref "refs/remotes/origin/$FORK_BRANCH" HEAD

  git checkout -q "$BASE"
  case "$mode" in
    rename)
      mkdir -p toolkit/components/downloads/new
      git mv toolkit/components/downloads/DownloadIntegration.sys.mjs \
             toolkit/components/downloads/new/DownloadIntegration.sys.mjs
      # Moved *and* edited, so exact rename detection alone cannot match it.
      perl -pi -e 's/^5$/5 UPSTREAM EDIT/' \
        toolkit/components/downloads/new/DownloadIntegration.sys.mjs
      git commit -qam "upstream: move DownloadIntegration"
      ;;
    conflict)
      perl -pi -e 's/^20$/20 UPSTREAM SAME LINE/' \
        toolkit/components/downloads/DownloadIntegration.sys.mjs
      git commit -qam "upstream: touch the same line"
      ;;
    delete)
      git rm -q toolkit/components/downloads/DownloadIntegration.sys.mjs
      git commit -qam "upstream: delete the file"
      ;;
    clean)
      perl -pi -e 's/^5$/5 UPSTREAM EDIT/' \
        toolkit/components/downloads/DownloadIntegration.sys.mjs
      git commit -qam "upstream: unrelated edit"
      ;;
    *) echo "unknown mode: $mode" >&2; exit 1 ;;
  esac
  git tag -f RELEASE >/dev/null

  # apply_patch_onto fetches the tag from the upstream remote.
  git remote add upstream "$ROOT/repo" 2>/dev/null || true

  SRC="$ROOT/repo"
  STATE="$ROOT/state"
  export SRC STATE
  echo "$BASE" > "$STATE/fork-base"
}

. "$FUNCS"

DL=toolkit/components/downloads/DownloadIntegration.sys.mjs

echo "=== 1. upstream renamed a file the series edits ==="
setup_repo rename
if apply_patch_onto RELEASE; then
  moved=toolkit/components/downloads/new/DownloadIntegration.sys.mjs
  grep -q '20 FORK EDIT' "$moved" \
    && ok "fork edit followed the rename" || bad "fork edit lost"
  grep -q '5 UPSTREAM EDIT' "$moved" \
    && ok "upstream edit preserved" || bad "upstream edit lost"
  [ -f toolkit/components/test_determining_filename.js ] \
    && ok "file the series adds is present" || bad "added file missing"
  [ -e tools/fork/config.sh ] \
    && bad "tooling leaked into the build tree" || ok "tools/fork excluded"
  [ -e .woodpecker/firefox-fork.yaml ] \
    && bad ".woodpecker leaked into the build tree" || ok ".woodpecker excluded"
else
  bad "a rename was reported as a conflict"
fi

echo "=== 2. rerun with nothing changed short-circuits ==="
out="$(apply_patch_onto RELEASE 2>&1)"
echo "$out" | grep -q 'skipping' \
  && ok "marker short-circuited the rerun" || bad "rerun did not skip: $out"

echo "=== 3. upstream edited the same line ==="
setup_repo conflict
if apply_patch_onto RELEASE; then
  bad "a genuine conflict was accepted"
else
  ok "conflict reported"
  grep -q '<<<<<<<' "$DL" \
    && ok "conflict markers left for inspection" || bad "no conflict markers"
  [ -s "$STATE/fork-commit" ] \
    && ok "fork-commit recorded for reproduction" || bad "no fork-commit"
  [ -e "$STATE/last-patch" ] \
    && bad "last-patch survived a failure" || ok "last-patch cleared"
fi

echo "=== 4. retrying after a conflict is not blocked by leftovers ==="
out="$(apply_patch_onto RELEASE 2>&1)"
echo "$out" | grep -qi 'already in progress\|would be overwritten' \
  && bad "retry blocked by leftover state: $out" \
  || ok "retry reached the merge again"

echo "=== 5. upstream deleted the file outright ==="
setup_repo delete
out="$(apply_patch_onto RELEASE 2>&1)"
if [ $? -eq 0 ]; then
  bad "a deleted file was silently accepted"
else
  # Must fail at the merge. A fetch or checkout error would pass a bare
  # exit-status check for entirely the wrong reason.
  echo "$out" | grep -q 'CONFLICT (modify/delete)' \
    && ok "reported as a modify/delete conflict" \
    || bad "failed before reaching the merge: $out"
fi

echo "=== 6. ordinary unrelated upstream edit ==="
setup_repo clean
if apply_patch_onto RELEASE; then
  grep -q '20 FORK EDIT' "$DL" && grep -q '5 UPSTREAM EDIT' "$DL" \
    && ok "both edits present" || bad "merge dropped an edit"
else
  bad "an unrelated edit was reported as a conflict"
fi

cd /
echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
