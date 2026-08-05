#!/bin/bash
# Poll upstream Firefox for new releases and rebuild the fork when one appears.
#
# Runs as PID 1 in the builder container. Everything durable lives on mounted
# volumes: /src (checkout), /state (toolchains, sccache, signing key, markers),
# /obj (object dirs), /www (what nginx serves), /vs (MSVC for cross-compiling).

set -uo pipefail

FORK_REPO="${FORK_REPO:-https://github.com/ssm9/firefox}"
FORK_BRANCH="${FORK_BRANCH:-ssm9/fork-build}"
UPSTREAM="${UPSTREAM:-https://github.com/mozilla-firefox/firefox}"
POLL_INTERVAL="${POLL_INTERVAL:-21600}"   # 6h
BUILD_JOBS="${BUILD_JOBS:-}"
NOTIFY_URL="${NOTIFY_URL:-}"

SRC=/src/firefox
# Tooling lives in its own small checkout so $SRC can be a pure release-tag
# tree. Folding it into the applied patch would mean this script could be
# rewritten underneath itself while running.
TOOLS=/src/fork-tools
FORK=$TOOLS/tools/fork
STATE=/state
WWW=/www

export MOZBUILD_STATE_PATH=/state/mozbuild
export SCCACHE_DIR=/state/sccache
export FORK_NSS_DIR=/state/mar-nss

# mach bootstrap installs Rust with rustup, which defaults to $HOME/.cargo
# (python/mozboot/mozboot/base.py:546). $HOME is inside the container and is
# not a volume, so the toolchain disappeared whenever the container was
# recreated, leaving configure to fail with "Rust compiler not found" even
# though bootstrap had already run. Point both at the state volume.
export CARGO_HOME=/state/cargo
export RUSTUP_HOME=/state/rustup
export PATH="$CARGO_HOME/bin:$PATH"

# Built MARs and installers, staged here between packaging and publishing.
# Deliberately on the state volume rather than /tmp: under CI each phase runs
# in its own container, so anything left in /tmp is invisible to the next step.
ARTIFACTS="${FORK_ARTIFACTS:-$STATE/artifacts}"

# Whether this invocation should fetch. main() narrows it per phase; the
# default keeps the ensure_* functions safe under `set -u` for any caller.
FORK_REFRESH="${FORK_REFRESH:-1}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Pause before exiting. The container restarts automatically, and every fatal
# error here is a misconfiguration that needs a human, so exiting immediately
# would spin the container and bury the message in restart noise.
die() { log "FATAL: $*"; sleep 60; exit 1; }

notify() {
  local msg="$1"
  log "$msg"
  if [ -n "$NOTIFY_URL" ]; then
    curl -fsS -m 20 -d "$msg" "$NOTIFY_URL" >/dev/null 2>&1 || \
      log "WARNING: notification POST failed"
  fi
}

write_status() {
  # Served at /status.json so the state of the last run is visible without
  # shelling into the container.
  mkdir -p "$WWW"
  cat > "$WWW/status.json.tmp" <<EOF
{
  "state": "$1",
  "detail": $(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "version": "${3:-}",
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  mv "$WWW/status.json.tmp" "$WWW/status.json"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  if [ -z "${FORK_UPDATE_HOST:-}" ] || [ "$FORK_UPDATE_HOST" = "CHANGEME.ts.net" ]; then
    die "FORK_UPDATE_HOST is unset or still the placeholder. Set it to the \
Tailscale MagicDNS name of this machine in the compose file. It is compiled \
into every build and cannot be changed afterwards without stranding installs."
  fi

  if [ ! -d "$FORK_NSS_DIR" ] || [ ! -s "$FORK_NSS_DIR/release_primary.der" ]; then
    die "No MAR signing key and certificate at $FORK_NSS_DIR. Generate them \
with tools/fork/gen_mar_key.sh and put the whole directory on the state \
volume. Without them, builds cannot be signed and installs would reject their \
own updates."
  fi
}

# The update URL is baked into the binary at compile time. If application.ini.in
# and the configured host disagree, the build silently ships pointing at the
# wrong server and never updates. Refuse to build rather than discover that
# weeks later.
check_url_consistency() {
  local baked expected
  # [a-z]*:// rather than https\?:// -- the latter is a GNU extension and this
  # check is worth being able to run outside the container.
  baked="$(sed -n 's|^URL=\([a-z]*://[^/]*\)/updates/.*|\1|p' \
    "$SRC/build/application.ini.in" | head -1)"
  expected="${FORK_UPDATE_SCHEME}://${FORK_UPDATE_HOST}"

  if [ -z "$baked" ]; then
    die "Could not parse the update URL out of build/application.ini.in. The \
fork patch that rewrites it may have failed to apply."
  fi

  if [ "$baked" != "$expected" ]; then
    die "Update URL mismatch: application.ini.in has '$baked' but the \
configuration says '$expected'. Fix one of them before building. Scheme counts \
as much as hostname -- a build compiled for https that is served over http \
will never find its manifest."
  fi

  log "Update URL: $expected (matches application.ini.in)"
}

# The certificate compiled into the updater decides which MARs an install will
# accept. It lives on the state volume rather than in git, so it has to be
# copied in after every checkout -- the tag checkout restores upstream's, which
# are Mozilla's own certificates. Building against those would produce installs
# that reject their own updates.
#
# Which file the build actually reads depends on the update channel
# (toolkit/mozapps/update/updater/moz.build:66). Only beta/release/esr use
# release_*.der; the nightly channels use nightly_aurora_level3_*.der; anything
# else -- including a custom channel name like this fork's -- falls through to
# dep1.der/dep2.der, Mozilla's throwaway test certificates. Overwriting
# release_*.der for a channel the build classifies as "other" silently achieves
# nothing, and the updater ships trusting a certificate nobody holds the key
# for. Mirror that selection here so the certificate lands where it is read.
install_mar_cert() {
  local dest="$SRC/toolkit/mozapps/update/updater"
  local primary secondary

  case "$FORK_CHANNEL" in
    beta|release|esr)
      primary=release_primary.der
      secondary=release_secondary.der
      ;;
    nightly|aurora|nightly-*)
      primary=nightly_aurora_level3_primary.der
      secondary=nightly_aurora_level3_secondary.der
      ;;
    *)
      primary=dep1.der
      secondary=dep2.der
      ;;
  esac

  for n in release_primary release_secondary; do
    if [ ! -s "$FORK_NSS_DIR/$n.der" ]; then
      die "Missing $FORK_NSS_DIR/$n.der. Generate the signing key with \
tools/fork/gen_mar_key.sh and put its output on the state volume."
    fi
  done

  cp -f "$FORK_NSS_DIR/release_primary.der" "$dest/$primary" \
    || die "could not install $primary"
  cp -f "$FORK_NSS_DIR/release_secondary.der" "$dest/$secondary" \
    || die "could not install $secondary"

  log "Installed fork MAR certificates as $primary / $secondary (channel $FORK_CHANNEL)"
}

# ---------------------------------------------------------------------------
# Source tree
# ---------------------------------------------------------------------------

# The tooling checkout: scripts, mozconfigs and the pipeline definition. Kept
# separate from the Firefox tree and sparse, so it is a few megabytes and can be
# updated without touching $SRC at all.
ensure_tools() {
  if [ ! -d "$TOOLS/.git" ]; then
    # --depth=1 matters. Without it a blobless clone still fetches every commit
    # and tree in mozilla-central's history -- gigabytes, for a checkout that
    # only ever needs the branch tip. With it this is well under 100 MB.
    log "Cloning tooling from $FORK_REPO branch $FORK_BRANCH"
    git clone --depth=1 --filter=blob:none --sparse --branch "$FORK_BRANCH" \
      "$FORK_REPO" "$TOOLS" || die "tooling clone failed"
    git -C "$TOOLS" sparse-checkout set tools/fork .woodpecker \
      || die "sparse-checkout failed"
  fi

  # --add would append a duplicate on every invocation, and concurrent steps
  # writing the same config file is a needless risk.
  git config --global --get-all safe.directory 2>/dev/null | grep -qx "$TOOLS" \
    || git config --global --add safe.directory "$TOOLS"

  [ -f "$FORK/config.sh" ] || die "tooling checkout has no tools/fork/config.sh"

  if [ "$FORK_REFRESH" != "1" ]; then
    return 0
  fi

  # --depth=1 again: the clone is shallow, and a full fetch would pull in the
  # history it was created to avoid.
  git -C "$TOOLS" fetch --depth=1 origin "$FORK_BRANCH" \
    || die "tooling fetch failed"
  git -C "$TOOLS" checkout -f -B fork-tools FETCH_HEAD \
    || die "could not check out tooling"
}

ensure_source() {
  if [ ! -d "$SRC/.git" ]; then
    # --progress because git stays silent when stderr is not a TTY, which in
    # `docker logs` makes a 20+ minute clone look like a hang.
    log "Cloning $FORK_REPO (20+ min the first time)"
    git clone --progress "$FORK_REPO" "$SRC" || die "clone failed"
  fi

  cd "$SRC" || die "cannot enter $SRC"
  git config user.name "fork build server"
  git config user.email "noreply@localhost"

  # Rename detection is the whole reason the fork changes are applied by
  # cherry-pick, and git switches it off when a diff has more renames to
  # consider than the limit allows -- printing a warning and silently
  # degrading to the behaviour we are trying to avoid. A release-to-release
  # diff of mozilla-central is large enough to hit the defaults. Exact renames
  # are always detected regardless; this is what buys detection of a file that
  # was moved *and* edited.
  git config merge.renameLimit 20000
  git config diff.renameLimit 20000
  git config --global --get-all safe.directory 2>/dev/null | grep -qx "$SRC" \
    || git config --global --add safe.directory "$SRC"

  git remote get-url upstream >/dev/null 2>&1 || \
    git remote add upstream "$UPSTREAM"

  if [ "$FORK_REFRESH" != "1" ]; then
    return 0
  fi

  git fetch origin --prune || die "fetch origin failed"
}

# Where the fork's own commits begin. Derived rather than configured: the fork
# branch and the upstream default branch diverge exactly there, so git already
# knows it. $STATE/fork-base still overrides, for a series based somewhere the
# merge base cannot express.
patch_base() {
  if [ -s "$STATE/fork-base" ]; then
    tr -d '[:space:]' < "$STATE/fork-base"
    return 0
  fi
  git -C "$SRC" merge-base "origin/$FORK_BRANCH" origin/main 2>/dev/null
}

ensure_bootstrap() {
  # The marker alone is not enough. Parts of what bootstrap installs live
  # outside MOZBUILD_STATE_PATH -- rustup writes to CARGO_HOME -- so the marker
  # can survive while the toolchain it recorded does not. Verify the compiler
  # is actually reachable and re-bootstrap if it is not, rather than failing in
  # configure several minutes later.
  if [ -f "$STATE/.bootstrapped" ] && command -v rustc >/dev/null 2>&1; then
    return
  fi

  if [ -f "$STATE/.bootstrapped" ]; then
    log "Bootstrap marker present but rustc is missing; bootstrapping again"
  fi

  log "Running mach bootstrap"
  cd "$SRC" || die "cannot enter $SRC"
  ./mach --no-interactive bootstrap --application-choice browser \
    || die "mach bootstrap failed"
  touch "$STATE/.bootstrapped"
}

# The win64 build runs midl.exe under wine to compile the accessibility IDL.
# wine needs a 32-bit runtime even to launch 64-bit executables; without it
# every midl invocation fails with "/lib/ld-linux.so.2: could not open".
# Mozilla's own build image installs the same packages for the same reason
# (taskcluster/docker/debian-build/Dockerfile:11).
ensure_wine_runtime() {
  if [ -e /lib/ld-linux.so.2 ]; then
    return 0
  fi

  log "Installing the 32-bit runtime wine needs"
  apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    libc6-i386 lib32gcc-s1 lib32stdc++6 lib32z1 \
    || { log "ERROR: could not install the 32-bit runtime"; return 1; }
}

# mach bootstrap installs only the host Rust target. Cross-compiling needs the
# target's standard library too, or configure fails its trial compile with
# "can't find crate for `std`".
ensure_rust_target() {
  local rust_target="$1"

  if rustup target list --installed 2>/dev/null | grep -qx "$rust_target"; then
    return 0
  fi

  log "Adding Rust target $rust_target"
  rustup target add "$rust_target" || {
    log "ERROR: could not add Rust target $rust_target"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Patching
# ---------------------------------------------------------------------------

# Squash the fork branch into a single commit parented on the patch base.
#
# Built as a commit rather than a diff so the changes can be applied by the
# merge machinery, which needs the excluded paths neutralised in the tree
# first. Neutralised, not removed: the commit is diffed against the base, so a
# path simply deleted from the tree reads as "the fork deletes this file".
# Upstream has .github/workflows, which the fork does not touch, and expressing
# that as a deletion conflicts the moment upstream edits one of those files --
# "deleted in <commit> and modified in HEAD". Restoring the base's own version
# of each excluded path makes the diff empty there instead, which is what the
# `git diff ':!path'` pathspec used to achieve.
#
# All of it happens in a scratch index, so nothing here touches the real index
# or the working tree -- this runs before the checkout, while the tree is still
# whatever the last cycle left behind.
#
# Echoes the commit.
build_fork_commit() {
  local base="$1"
  local index="$STATE/fork-index"

  # Paths the build tree must never receive from the fork branch.
  local excluded=(tools/fork .woodpecker .github)

  rm -f "$index"

  GIT_INDEX_FILE="$index" git read-tree "origin/$FORK_BRANCH" || return 1
  # --force because the scratch index deliberately disagrees with both HEAD and
  # the working tree, which is the safety check git rm would otherwise apply.
  GIT_INDEX_FILE="$index" git rm -rq --cached --force --ignore-unmatch \
    -- "${excluded[@]}" > /dev/null || return 1

  # ls-tree's output is already the format --index-info reads. Paths the base
  # does not have -- tools/fork, .woodpecker -- match nothing and stay absent,
  # which is correct: the base does not have them either, so the diff is still
  # empty there.
  git ls-tree -r "$base" -- "${excluded[@]}" \
    | GIT_INDEX_FILE="$index" git update-index --index-info || return 1

  local tree
  tree="$(GIT_INDEX_FILE="$index" git write-tree)" || return 1
  rm -f "$index"

  git commit-tree "$tree" -p "$base" \
    -m "fork: squashed fork changes for the build server" || return 1
}

# Apply the fork's changes onto a release tag as a single squashed commit,
# rather than replaying the commit series.
#
# The commit history is worth keeping on the upstreamable branch, but the build
# only needs the resulting tree. Squashing has two concrete advantages:
#
#  - One conflict surface. A rebase can stop 34 separate times; cherry-picking
#    one squashed commit stops at most once.
#  - The tree stays anchored to a release tag. Rebasing reset the checkout to
#    the mozilla-central-based branch and rewrote it forward to the tag every
#    cycle -- 12,538 files each way. Moving tag to tag touches a few hundred,
#    so a new release rebuilds incrementally instead of almost entirely.
#
# Cherry-pick rather than `git apply --3way`, which is what this used to do.
# git apply matches a patch to files by path and has no rename detection, so
# an upstream move of a file the fork touches failed with
# "<path>: does not exist in index" even when the change itself still applied
# cleanly -- and failed with the whole apply rolled back, leaving no conflict
# markers and a pristine tree to diagnose from. The merge machinery follows the
# rename and applies the change at its new path instead. Renames like the
# .jsm -> .sys.mjs migration hit three of the files this series touches.
apply_patch_onto() {
  local tag="$1"

  local base
  base="$(patch_base)"
  if [ -z "$base" ]; then
    die "Could not determine the patch base. Either origin/main is missing, or \
the fork branch shares no history with it. Set it explicitly with: \
echo <upstream-commit> > $STATE/fork-base"
  fi

  cd "$SRC" || die "cannot enter $SRC"

  # Full fetch, never --depth=1: a shallow tag has no history, so the three-way
  # merge has no common ancestor to work from and reports conflicts on hunks
  # that apply perfectly well.
  git fetch upstream "refs/tags/$tag:refs/tags/$tag" \
    || die "could not fetch tag $tag"

  # Checked out here rather than inside build_fork_commit, which runs in a
  # command substitution -- a die() in there would have its message captured as
  # the function's output instead of reaching the log.
  local commit tree origin_sha head_sha marker
  commit="$(build_fork_commit "$base")" \
    || die "could not build the squashed fork commit"
  tree="$(git rev-parse "$commit^{tree}")"

  if [ "$tree" = "$(git rev-parse "$base^{tree}")" ]; then
    die "The fork branch's tree matches the base once tooling is excluded, so \
there is nothing to apply. origin/$FORK_BRANCH may not contain the patch \
series, or the base is wrong."
  fi

  origin_sha="$(git rev-parse "origin/$FORK_BRANCH")"
  head_sha="$(git rev-parse HEAD 2>/dev/null || echo none)"
  # The tree, not the commit: commit-tree stamps the current time, so the
  # commit differs on every run while the tree is content-addressed and only
  # changes when the fork's changes do.
  marker="$tag $origin_sha $base $head_sha $tree"

  if [ -f "$STATE/last-patch" ] \
      && [ "$(cat "$STATE/last-patch")" = "$marker" ]; then
    log "Tree already at $tag with the current fork changes; skipping"
    return 0
  fi

  log "Checking out $tag and cherry-picking the fork changes ($commit)"

  # Clear the sequencer state a previous conflicted attempt left behind, or the
  # cherry-pick below refuses to start with "a cherry-pick is already in
  # progress". --quit rather than --abort: the checkout that follows sets the
  # tree regardless, and --abort would first try to restore a HEAD that is
  # about to be replaced.
  git cherry-pick --quit 2>/dev/null || true

  # -f discards the certificates install_mar_cert wrote last cycle and the
  # previous application, including any half-merged files and conflicted adds
  # from a failed attempt. Object directories are gitignored and survive, which
  # is what keeps the rebuild incremental.
  git checkout -f "refs/tags/$tag" || die "could not check out $tag"

  # A conflict means upstream changed code the series touches. Stop rather than
  # build a half-merged download path: the conflict markers are left in place,
  # so the failure is inspectable in $SRC.
  if ! git cherry-pick "$commit"; then
    log "The fork changes do not merge onto $tag"
    echo "$commit" > "$STATE/fork-commit"
    rm -f "$STATE/last-patch"
    return 1
  fi

  # Recorded so the next cycle can tell the tree is already correct. HEAD and
  # the tree are included so a manual checkout, or an edit to the branch,
  # invalidates it rather than being silently kept.
  echo "$commit" > "$STATE/fork-commit"
  echo "$tag $origin_sha $base $(git rev-parse HEAD) $tree" \
    > "$STATE/last-patch"
  return 0
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# The MSVC toolchain needed to cross-compile Windows cannot be redistributed by
# Mozilla, but it can be fetched straight from Microsoft on Linux: vsdownload is
# vendored at third_party/python/vsdownload and get_vs.py handles the
# non-Windows extraction layout. No Windows machine or Visual Studio install is
# involved. Downloading it means accepting Microsoft's Build Tools licence.
ensure_vs() {
  if [ -n "$(ls -A /vs 2>/dev/null)" ]; then
    return 0
  fi

  if [ ! -w /vs ]; then
    log "ERROR: /vs is empty and not writable, so the MSVC toolchain cannot \
be fetched. Mount it read-write, or drop win64 from FORK_TARGETS."
    return 1
  fi

  # vsdownload shells out to msiextract to unpack the SDK installers
  # (third_party/python/vsdownload/vsdownload.py:721). It is in the image, but
  # install it on demand too so an older image does not need rebuilding just
  # for this.
  if ! command -v msiextract >/dev/null 2>&1; then
    log "msiextract missing; installing msitools"
    apt-get update -qq && apt-get install -y -qq --no-install-recommends msitools \
      || { log "ERROR: could not install msitools"; return 1; }
  fi

  log "Fetching the MSVC toolchain into /vs (first run only, several GB)"
  cd "$SRC" || return 1
  ./mach python --virtualenv build \
    taskcluster/scripts/misc/get_vs.py build/vs/vs2026.yaml /vs || {
      log "ERROR: fetching the MSVC toolchain failed"
      # A half-written toolchain is worse than none: it would fail the build in
      # confusing ways every cycle rather than being retried cleanly.
      rm -rf /vs/* 2>/dev/null || true
      return 1
    }
  log "MSVC toolchain ready"
}

# Fix the build ID every artifact in this cycle is stamped with.
#
# Left to itself, build/variables.py:buildid_header stamps datetime.now() every
# time buildid.h is regenerated, and it is regenerated more than once per cycle
# -- packaging re-runs it after the compile is over. The published 153.0.1
# builds came out with the launcher compiled at 20260802155501 and the
# application.ini staged beside it reading 20260802155509.
#
# That gap breaks updates rather than merely looking untidy. application.ini is
# compiled into the launcher as application.ini.h (build/moz.build:122), and
# appinfo.appBuildID -- what about:support shows, and what the update service
# compares against the manifest -- is read from that compiled-in copy
# (browser/app/ApplicationData.cpp), never from the file on disk. make_mar.sh
# reads the file, so the manifest advertised a build ID no install could ever
# report: every check offered the same update, applying it changed nothing, and
# the next check offered it again.
#
# Recorded through ci_set rather than exported because under CI each phase is
# its own process, and because `./mach build` and `./mach package` have to
# agree -- the regeneration happens between them.
mint_buildid() {
  local id; id="$(date -u +%Y%m%d%H%M%S)"
  ci_set buildid "$id"
  log "Build ID for this cycle: $id"
}

build_target() {
  local target="$1"
  cd "$SRC" || die "cannot enter $SRC"

  # See mint_buildid. Deliberately fatal rather than falling back to a fresh
  # stamp: a value minted here would differ from the one the other targets and
  # the other phases used, which is the problem this exists to prevent.
  MOZ_BUILD_DATE="$(ci_get buildid)"
  if [ -z "$MOZ_BUILD_DATE" ]; then
    log "ERROR: no build ID recorded for this cycle; run the detect step first"
    return 1
  fi
  export MOZ_BUILD_DATE

  export MOZCONFIG="$FORK/mozconfigs/$target"
  [ -n "$BUILD_JOBS" ] && export MOZ_MAKE_FLAGS="-j$BUILD_JOBS"

  # Note: exporting MOZ_OBJDIR does nothing here. mozbuild only consults the
  # environment variable when there is no mozconfig at all
  # (python/mozbuild/mozbuild/mozconfig.py:121); with MOZCONFIG set that branch
  # is skipped and the objdir falls back to the default under topsrcdir.
  # Rather than pin it, ask mach where it actually is after the build, so this
  # keeps working however the objdir ends up being configured.

  if [ ! -f "$MOZCONFIG" ]; then
    log "ERROR: no mozconfig at $MOZCONFIG"
    return 1
  fi

  if [ "$target" = "win64" ]; then
    ensure_vs || return 1
    ensure_rust_target x86_64-pc-windows-msvc || return 1
    ensure_wine_runtime || return 1
    # WINSYSROOT, not VSPATH: configure reads WINSYSROOT
    # (build/moz.configure/windows-toolchain.configure:62) and expects a
    # directory containing VC, "Windows Kits/10" and DIA SDK, which is what
    # get_vs.py produces. Setting it also stops configure trying to bootstrap
    # a "vs" toolchain, which is not publicly downloadable.
    export WINSYSROOT=/vs
  fi

  if [ "$target" = "macos-aarch64" ]; then
    ensure_rust_target aarch64-apple-darwin || return 1
    # Nothing else to arrange. The macOS SDK is not in the image and is not
    # mounted the way /vs is: configure fetches it on the first build through
    # bootstrap_path (build/moz.configure/toolchain.configure:260), which
    # downloads Apple's command line tools package from swcdn.apple.com and
    # unpacks it under MOZBUILD_STATE_PATH -- on the state volume, so once.
    # The linker is clang's own lld, so there is no cctools to install either.
  fi

  # build/variables.py:95 only derives the source stamp from Mercurial or a
  # sourcestamp.txt. This tree is git with neither, so source-repo.h comes out
  # empty, and packaging then fails preprocessing it with "no preprocessor
  # directives found" -- after the whole compile has succeeded. Supply the
  # values through the environment, which toolkit/moz.configure:74 exists for.
  #
  # MOZ_SOURCE_CHANGESET has to be set explicitly: with MOZ_SOURCE_REPO set and
  # it absent, variables.py falls back to querying Mercurial and raises.
  # MOZ_INCLUDE_SOURCE_INFO is what makes MOZ_SOURCE_URL get written at all,
  # and packaging reads exactly that key.
  export MOZ_SOURCE_REPO="$FORK_REPO"
  export MOZ_SOURCE_CHANGESET="$(git rev-parse HEAD)"
  export MOZ_INCLUDE_SOURCE_INFO=1

  log "Building $target"
  ./mach build || return 1
  ./mach package || return 1

  # Ask mach where it actually built, rather than assuming. Sets the global
  # FORK_OBJDIR for the caller to hand to make_mar.sh.
  FORK_OBJDIR="$(./mach environment --format=json 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["topobjdir"])')"

  if [ -z "$FORK_OBJDIR" ] || [ ! -d "$FORK_OBJDIR" ]; then
    log "ERROR: could not determine the object directory for $target"
    return 1
  fi

  log "Object directory for $target: $FORK_OBJDIR"

  # Remember the first signmar that actually runs here. signmar is a Program,
  # not a HostProgram (modules/libmar/tool/moz.build), so a cross-compiled
  # target builds one for that target -- win64 produces a Windows executable
  # that cannot run on the builder. Signing does not care about architecture,
  # so the native build's copy is reused for every subsequent target.
  #
  # Recorded on disk, not just exported. Under CI each phase is its own
  # container, so an exported variable never reaches the step that needs it:
  # win64's packaging would fall back to its own objdir and find a .exe.
  if [ -z "$(ci_get signmar)" ]; then
    local candidate="$FORK_OBJDIR/dist/bin/signmar"
    if [ -x "$candidate" ]; then
      # `|| rc=$?` rather than a bare call: signmar exits non-zero for a usage
      # message, so this would kill the script if `set -e` were ever added here.
      local rc=0
      "$candidate" -h >/dev/null 2>&1 || rc=$?
      if [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ]; then
        ci_set signmar "$candidate"
        export FORK_SIGNMAR="$candidate"
        log "Using signmar from $target: $candidate"
      fi
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------

# Publish one target. Targets are independent -- each has its own MAR and its
# own manifest paths -- so this is safe to run for two targets concurrently,
# and lets one ship as soon as it is ready instead of waiting for the other.
publish_target() {
  local version="$1" target="$2" meta="$3"

  if [ ! -s "$meta" ]; then
    log "ERROR: no metadata at $meta for $target"
    return 1
  fi

  local dl_dir="$WWW/downloads/$version"
  mkdir -p "$dl_dir"

  # Order matters: the MAR must be downloadable *before* the manifest points at
  # it, or a client checking in between sees a manifest referencing a 404 and
  # records a failed update.
  log "Publishing $target artifacts for $version"
  cp -f "$ARTIFACTS/firefox-$version.$target.complete.mar" "$dl_dir/" || return 1
  # Anchored on the version, not a bare *.tar.xz. The staging directory is not
  # emptied between releases under CI, so a bare glob copied every release's
  # installers into every release's download directory -- 153.0.3 shipped with
  # 153.0.1's archives sitting beside it, and the waste compounded per cycle.
  # The trailing dot matters: it stops 153.0.1 from matching 153.0.11.
  case "$target" in
    linux64)       cp -f "$ARTIFACTS/firefox-$version".*.tar.xz "$dl_dir/" 2>/dev/null || true ;;
    win64)         cp -f "$ARTIFACTS/firefox-$version".*.zip "$dl_dir/" 2>/dev/null || true ;;
    macos-*)       cp -f "$ARTIFACTS/firefox-$version".*.tar.gz "$dl_dir/" 2>/dev/null || true ;;
  esac
  sync

  # Staging is per target. A shared directory would be removed and rewritten by
  # whichever publish ran second, discarding the other's manifests.
  log "Publishing $target manifests"
  local staging="$WWW/.manifests-staging-$target"
  rm -rf "$staging"
  python3 "$FORK/gen_update_manifest.py" \
    --metadata "$meta" \
    --outdir "$staging" \
    --channel "$FORK_CHANNEL" \
    --release-base-url "$FORK_DOWNLOAD_BASE_URL/$version" || return 1

  mkdir -p "$WWW/updates"
  cp -rf "$staging"/* "$WWW/updates/" || return 1
  rm -rf "$staging"
  sync
  return 0
}

# Drop download directories for releases nothing is being offered any more.
#
# A release costs roughly 575 MB -- three installers, three MARs and the
# Windows xpt archive -- and upstream ships one every few weeks, so keeping
# every one of them fills the dataset at something like 12 GB a year for builds
# nobody can be served. Only complete MARs are produced and the manifest names
# exactly one of them, so nothing needs the older directories to construct an
# update; they are kept only so a fresh install of a recent release is still
# possible. FORK_KEEP_RELEASES=0 turns this off.
prune_downloads() {
  local dir="$WWW/downloads"
  local keep="${FORK_KEEP_RELEASES:-3}"

  [ -d "$dir" ] || return 0

  case "$keep" in
    ''|*[!0-9]*)
      log "WARNING: FORK_KEEP_RELEASES=$keep is not a number; keeping everything"
      return 0
      ;;
  esac

  if [ "$keep" -eq 0 ]; then
    log "FORK_KEEP_RELEASES=0; not pruning downloads"
    return 0
  fi

  # sort -V so 153.0.10 sorts above 153.0.9, which a lexical sort would bury.
  local versions=() v
  while IFS= read -r v; do
    [ -n "$v" ] && [ -d "$dir/$v" ] && versions+=("$v")
  done < <(ls -1 "$dir" 2>/dev/null | sort -V)

  local total="${#versions[@]}"
  [ "$total" -gt "$keep" ] || return 0

  # Never remove a release some manifest still points at. When one target fails
  # to build, its manifest keeps advertising the last release that did, so the
  # newest directory is not necessarily the only one in use -- win64 can still
  # be offering two releases back while linux64 has moved on. Deleting that
  # directory turns its next update check into a 404, which the client records
  # as a failed update rather than retrying.
  local referenced
  referenced="$(find "$WWW/updates" -name update.xml -print0 2>/dev/null \
    | xargs -0 -r sed -n 's|.*/downloads/\([^/]*\)/.*|\1|p' 2>/dev/null \
    | sort -u)"

  local i
  for (( i = 0; i < total - keep; i++ )); do
    v="${versions[$i]}"
    if printf '%s\n' "$referenced" | grep -qxF -- "$v"; then
      log "Keeping $v: a manifest still points at it"
      continue
    fi
    log "Pruning $dir/$v"
    rm -rf "${dir:?}/${v:?}"
  done
}

# The install scripts, served beside the builds they install so a client is
# never sent somewhere else to fetch them. They come out of the tooling
# checkout, so what is served tracks the branch that produced the build rather
# than whatever was copied onto the NAS by hand at deploy time.
publish_install_scripts() {
  local dir="$WWW/install" script name tmp
  mkdir -p "$dir" || return 1

  for script in "$FORK/install-linux.sh" "$FORK/install-macos.sh"; do
    name="$(basename "$script")"
    if [ ! -f "$script" ]; then
      log "WARNING: $name is missing from the tooling checkout"
      continue
    fi

    # Copied under a temporary name and renamed into place. Steps run
    # concurrently, and a client fetching a half-written script would run it.
    tmp="$(mktemp "$dir/.$name.XXXXXX")" || return 1
    if cp -f "$script" "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$dir/$name"; then
      continue
    fi
    rm -f "$tmp"
    log "WARNING: could not publish $name"
  done
}

# Loop entry point: publish every target that produced metadata. Shares
# publish_target with the CI path so the two cannot diverge.
publish() {
  local version="$1"
  shift
  local meta target rc=0

  for meta in "$@"; do
    target="$(basename "$meta" .mar.json)"
    publish_target "$version" "$target" "$meta" || rc=1
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# One cycle
# ---------------------------------------------------------------------------

run_once() {
  ensure_tools
  # After the fetch, so a change to the scripts reaches the server on the next
  # cycle rather than waiting for the container to be restarted.
  publish_install_scripts
  ensure_source

  local last_built=""
  [ -f "$STATE/last-built" ] && last_built="$(tr -d '[:space:]' < "$STATE/last-built")"

  local check version tag should
  check="$(python3 "$FORK/check_release.py" \
    --remote "$UPSTREAM" --last-built "$last_built" 2>&1)" || {
    log "release check failed: $check"
    write_status "error" "upstream release check failed" ""
    return 1
  }

  version="$(sed -n 's/^version=//p' <<<"$check")"
  tag="$(sed -n 's/^tag=//p' <<<"$check")"
  should="$(sed -n 's/^should_build=//p' <<<"$check")"

  if [ "$should" != "true" ]; then
    log "Up to date at $version"
    write_status "idle" "up to date" "$version"
    return 0
  fi

  notify "Firefox $version released; starting fork build"
  write_status "building" "patching onto $tag" "$version"

  if ! apply_patch_onto "$tag"; then
    notify "The fork changes do not merge onto $tag. Upstream changed code the \
onDeterminingFilename series touches. No build was published for $version. \
The conflict markers are left in $SRC for inspection; resolve it on \
$FORK_BRANCH and push. Reproduce by hand with: git -C $SRC cherry-pick \
\$(cat $STATE/fork-commit)"
    write_status "conflict" "patch series does not merge onto $tag" "$version"
    return 1
  fi

  check_url_consistency
  install_mar_cert
  ensure_bootstrap
  mint_buildid

  rm -rf "$ARTIFACTS"
  mkdir -p "$ARTIFACTS"

  # Targets are independent: each produces its own MAR and its own manifest, so
  # one failing is no reason to withhold the others. A target with no manifest
  # simply sees no update, which is strictly better than every target seeing
  # none because an unrelated one could not build.
  local metadata=()
  local built=""
  local failed=""
  local target
  for target in $FORK_TARGETS; do
    write_status "building" "compiling $target" "$version"

    if ! build_target "$target"; then
      log "Build failed for $target; continuing with the remaining targets"
      failed="$failed $target"
      continue
    fi

    # FORK_OBJDIR is set by build_target from mach's own view of the tree.
    if ! FORK_SRCDIR="$SRC" "$FORK/make_mar.sh" "$target" \
        "$FORK_OBJDIR" "$ARTIFACTS"; then
      log "MAR packaging or signing failed for $target; continuing"
      failed="$failed $target"
      continue
    fi

    # Version-anchored for the same reason as the publish side: dist/ keeps
    # every archive it has ever produced, because only a clobber empties it and
    # AUTOCLOBBER fires on the tree's CLOBBER file rather than on each build.
    case "$target" in
      linux64)       cp -f "$FORK_OBJDIR/dist/firefox-$version".*.tar.xz "$ARTIFACTS"/ 2>/dev/null || true ;;
      win64)         cp -f "$FORK_OBJDIR/dist/firefox-$version".*.zip "$ARTIFACTS"/ 2>/dev/null || true ;;
      macos-*)       cp -f "$FORK_OBJDIR/dist/firefox-$version".*.tar.gz "$ARTIFACTS"/ 2>/dev/null || true ;;
    esac

    metadata+=("$ARTIFACTS/$target.mar.json")
    built="$built $target"
  done

  if [ "${#metadata[@]}" -eq 0 ]; then
    notify "No target built successfully for $version. Nothing published. Failed:$failed"
    write_status "failed" "all targets failed:$failed" "$version"
    return 1
  fi

  if ! publish "$version" "${metadata[@]}"; then
    notify "Publishing failed for $version; the previous version is still being served."
    write_status "failed" "publish failed" "$version"
    return 1
  fi

  if [ -n "$failed" ]; then
    # last-built is deliberately not recorded. Doing so would mark this release
    # done and stop the failing targets from ever being retried until the next
    # release. Leaving it unset means the next cycle tries again -- cheap, since
    # the targets that succeeded are cached and rebuild in minutes.
    notify "Published $version for:$built -- still failing:$failed. Will retry."
    write_status "partial" "published:$built failing:$failed" "$version"
    return 1
  fi

  echo "$version" > "$STATE/last-built"
  # Only on a fully successful cycle. A partial one is exactly when a manifest
  # is still pointing at an older release, and the retry that follows will
  # prune once every target has caught up.
  prune_downloads
  notify "Published Firefox $version for:$built"
  write_status "ok" "published" "$version"
  return 0
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step mode
#
# A CI system runs each phase as its own process, so the state run_once keeps in
# shell variables -- the version being built, the tag, the object directory --
# has to survive between them. $STATE/ci holds it.
#
# The phases themselves are the same functions the loop calls, so both entry
# points exercise identical code rather than drifting apart.
# ---------------------------------------------------------------------------

CI_DIR="$STATE/ci"

ci_set() { mkdir -p "$CI_DIR"; printf '%s' "$2" > "$CI_DIR/$1"; }
ci_get() { [ -f "$CI_DIR/$1" ] && cat "$CI_DIR/$1" || echo ""; }

step_detect() {
  local last_built=""
  [ -f "$STATE/last-built" ] && last_built="$(tr -d '[:space:]' < "$STATE/last-built")"

  local check
  check="$(python3 "$FORK/check_release.py" \
    --remote "$UPSTREAM" --last-built "$last_built" 2>&1)" || {
    log "release check failed: $check"
    return 1
  }

  local version tag should
  version="$(sed -n 's/^version=//p' <<<"$check")"
  tag="$(sed -n 's/^tag=//p' <<<"$check")"
  should="$(sed -n 's/^should_build=//p' <<<"$check")"

  rm -rf "$CI_DIR"
  ci_set version "$version"
  ci_set tag "$tag"

  if [ "$should" != "true" ]; then
    ci_set skip 1
    log "Up to date at $version; later steps will no-op"
    write_status "idle" "up to date" "$version"
    return 0
  fi

  # Here rather than in step_build: every target in the pipeline has to be
  # stamped with the same value, and step_build runs once per target.
  mint_buildid

  # run_once does this per cycle; the step path had no equivalent, so under CI
  # the staging directory grew by a full set of installers and MARs every
  # release and never shrank. Only on the build path: a cycle that publishes
  # nothing has nothing to stage, and clearing it would discard artifacts a
  # half-finished earlier run might still be asked to publish.
  rm -rf "$ARTIFACTS"
  mkdir -p "$ARTIFACTS"

  log "Firefox $version needs building (tag $tag)"
  write_status "building" "detected $version" "$version"
  return 0
}

# Every later step calls this first. Woodpecker has no equivalent of halting a
# pipeline mid-run, so the steps run and return immediately instead. That keeps
# a no-op poll visible as a short green run rather than a failure.
step_should_skip() {
  if [ -n "$(ci_get skip)" ]; then
    log "Nothing to build; skipping"
    return 0
  fi
  return 1
}

step_patch() {
  step_should_skip && return 0
  local tag; tag="$(ci_get tag)"
  [ -n "$tag" ] || { log "no tag recorded; run detect first"; return 1; }

  if ! apply_patch_onto "$tag"; then
    notify "The fork changes do not merge onto $tag; conflicts left in $SRC. \
Reproduce with: git -C $SRC cherry-pick \$(cat $STATE/fork-commit)"
    write_status "conflict" "patch series does not merge onto $tag" "$(ci_get version)"
    return 1
  fi

  check_url_consistency
  install_mar_cert
  ensure_bootstrap
  return 0
}

step_build() {
  step_should_skip && return 0
  local target="${1:?usage: step build <target>}"
  local version; version="$(ci_get version)"

  write_status "building" "compiling $target" "$version"
  build_target "$target" || return 1

  # FORK_OBJDIR is discovered by build_target; hand it to the next step.
  ci_set "objdir-$target" "$FORK_OBJDIR"
  return 0
}

step_mar() {
  step_should_skip && return 0
  local target="${1:?usage: step mar <target>}"
  local objdir; objdir="$(ci_get "objdir-$target")"
  [ -n "$objdir" ] || { log "no object directory for $target; run build first"; return 1; }
  local version; version="$(ci_get version)"
  [ -n "$version" ] || { log "no version recorded; run detect first"; return 1; }

  # Recorded by whichever build produced a signmar that runs on this host. A
  # cross-compiled target's own copy is built for the target -- win64's is a
  # Windows executable -- so it cannot sign anything here.
  local signmar; signmar="$(ci_get signmar)"
  if [ -n "$signmar" ]; then
    export FORK_SIGNMAR="$signmar"
    log "Signing with $signmar"
  fi

  mkdir -p "$ARTIFACTS"
  FORK_SRCDIR="$SRC" "$FORK/make_mar.sh" "$target" "$objdir" "$ARTIFACTS" || return 1

  # Version-anchored: dist/ accumulates an archive per release built in that
  # object directory, and a bare glob staged all of them.
  case "$target" in
    linux64)       cp -f "$objdir/dist/firefox-$version".*.tar.xz "$ARTIFACTS"/ 2>/dev/null || true ;;
    win64)         cp -f "$objdir/dist/firefox-$version".*.zip "$ARTIFACTS"/ 2>/dev/null || true ;;
    macos-*)       cp -f "$objdir/dist/firefox-$version".*.tar.gz "$ARTIFACTS"/ 2>/dev/null || true ;;
  esac

  ci_set "mar-$target" ok
  return 0
}

# Publish a single target, as soon as it is ready. Running this per target
# means a slow or failing win64 no longer delays a finished linux64.
step_publish() {
  step_should_skip && return 0
  local target="${1:?usage: step publish <target>}"
  local version; version="$(ci_get version)"

  if [ -z "$(ci_get "mar-$target")" ]; then
    log "No MAR for $target; nothing to publish"
    return 1
  fi

  publish_target "$version" "$target" "$ARTIFACTS/$target.mar.json" || {
    notify "Publishing failed for $target on $version."
    return 1
  }

  ci_set "published-$target" ok
  notify "Published $version for $target"
  write_status "building" "published $target" "$version"
  return 0
}

# Runs after every target. Owns last-built, which cannot be written by the
# per-target steps: recording it while a target is still failing would mark the
# release done and stop it ever being retried.
step_finalize() {
  step_should_skip && return 0
  local version; version="$(ci_get version)"

  local built="" failed="" target
  for target in $FORK_TARGETS; do
    if [ -n "$(ci_get "published-$target")" ]; then
      built="$built $target"
    else
      failed="$failed $target"
    fi
  done

  if [ -z "$built" ]; then
    notify "No target published for $version. Failed:$failed"
    write_status "failed" "all targets failed:$failed" "$version"
    return 1
  fi

  if [ -n "$failed" ]; then
    notify "Published $version for:$built -- still failing:$failed. Will retry."
    write_status "partial" "published:$built failing:$failed" "$version"
    return 1
  fi

  echo "$version" > "$STATE/last-built"
  # Only on a fully successful cycle. A partial one is exactly when a manifest
  # is still pointing at an older release, and the retry that follows will
  # prune once every target has caught up.
  prune_downloads
  notify "Published Firefox $version for:$built"
  write_status "ok" "published" "$version"
  return 0
}

handover_to_intree() {
  local intree="$FORK/docker/build-loop.sh"
  if [ -z "${FORK_LOOP_REEXEC:-}" ] && [ -f "$intree" ] && ! cmp -s "$intree" "$0"; then
    log "In-tree build loop differs from the image copy; handing over to it"
    export FORK_LOOP_REEXEC=1
    exec bash "$intree" "$@"
  fi
}

run_step() {
  local cmd="${1:?usage: build-loop.sh step <detect|patch|build|mar|publish|finalize> [target]}"
  shift
  case "$cmd" in
    detect)   step_detect "$@" ;;
    patch)    step_patch "$@" ;;
    build)    step_build "$@" ;;
    mar)      step_mar "$@" ;;
    publish)  step_publish "$@" ;;
    finalize) step_finalize "$@" ;;
    *) log "unknown step: $cmd"; return 1 ;;
  esac
}

main() {
  [ -d "$STATE" ] || die "/state is not mounted"
  [ -d "$WWW" ] || die "/www is not mounted"
  mkdir -p "$MOZBUILD_STATE_PATH" "$SCCACHE_DIR" /obj /src

  # Only the phases that need fresh git state fetch. Under CI the build, mar,
  # publish and finalize steps run as separate processes -- two of them
  # concurrently -- against the same repositories, and simultaneous fetches
  # collide on .git/shallow.lock. They have no use for a fetch anyway: the tree
  # they build was fixed by the patch step.
  FORK_REFRESH=1
  if [ "${1:-}" = "step" ]; then
    case "${2:-}" in
      detect|patch) FORK_REFRESH=1 ;;
      *)            FORK_REFRESH=0 ;;
    esac
  fi
  export FORK_REFRESH

  # This script is baked into the image, because it has to exist before there
  # is a checkout to run it from. Once the checkout exists, hand over to the
  # in-tree copy if it differs, so fixes take effect by updating /src rather
  # than rebuilding the image. The guard prevents an exec loop.
  #
  # Deliberately before any git work. Handing over afterwards meant a fault in
  # ensure_tools killed the run before the in-tree copy loaded, so a fix to
  # ensure_tools itself could never be delivered through /src -- exactly the
  # situation the handover exists to avoid.
  handover_to_intree "$@"

  # config.sh lives in the tooling checkout, so it has to exist by now. Values
  # already set in the environment by the compose file win over its defaults.
  ensure_tools
  ensure_source

  # Try again: on a first run the checkout did not exist above, and
  # ensure_tools has just created it.
  handover_to_intree "$@"

  . "$FORK/config.sh" || die "could not source tools/fork/config.sh"

  preflight

  # Every invocation, not just a publish: under CI the phases are separate
  # processes, and this way the scripts land even on a run that never gets as
  # far as publishing a build.
  publish_install_scripts

  # Step mode: a CI system drives the phases and this exits after one.
  if [ "${1:-}" = "step" ]; then
    shift
    run_step "$@"
    exit $?
  fi

  log "Fork build server starting"
  log "  update host:   $FORK_UPDATE_HOST"
  log "  targets:       $FORK_TARGETS"
  log "  poll interval: ${POLL_INTERVAL}s"

  if [ "${RUN_ONCE:-0}" = "1" ]; then
    run_once
    exit $?
  fi

  while true; do
    run_once || log "cycle finished with errors; will retry"
    log "Sleeping ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
  done
}

main "$@"
