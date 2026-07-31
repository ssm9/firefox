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
fork commit that rewrites it may have been lost in a rebase."
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
# copied in after every rebase -- the rebase restores upstream's files, which
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

ensure_source() {
  if [ ! -d "$SRC/.git" ]; then
    # --branch matters: the fork's default branch is upstream's main, which
    # does not contain tools/fork at all. Cloning without it lands on main and
    # everything downstream fails looking for its own scripts.
    # --progress because git stays silent when stderr is not a TTY, which in
    # `docker logs` makes a 20+ minute clone look like a hang.
    log "Cloning $FORK_REPO branch $FORK_BRANCH (20+ min the first time)"
    git clone --progress --branch "$FORK_BRANCH" "$FORK_REPO" "$SRC" \
      || die "clone failed"
  fi

  cd "$SRC" || die "cannot enter $SRC"
  git config user.name "fork build server"
  git config user.email "noreply@localhost"
  git config --global --add safe.directory "$SRC"

  git remote get-url upstream >/dev/null 2>&1 || \
    git remote add upstream "$UPSTREAM"

  git fetch origin --prune || die "fetch origin failed"

  # Only check out when the tree is not already usable. This used to run every
  # cycle, which was expensive: it reset the tree from its rebased state back
  # to origin's, and rebase_onto then rewrote it forward again. Every file
  # differing between mozilla-central and the release tag was rewritten twice
  # per cycle, and the resulting mtime churn made make rebuild far more than
  # the content actually required. rebase_onto does its own checkout when it
  # genuinely needs to.
  if ! git rev-parse --verify --quiet fork-build >/dev/null 2>&1 \
      || [ ! -f "$SRC/tools/fork/config.sh" ]; then
    log "Checking out $FORK_BRANCH"
    git checkout -f -B fork-build "origin/$FORK_BRANCH" \
      || die "could not check out $FORK_BRANCH"
  fi
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
# Rebase
# ---------------------------------------------------------------------------

rebase_onto() {
  local tag="$1"

  if [ ! -f "$STATE/fork-base" ]; then
    die "No $STATE/fork-base. It must contain the upstream commit that \
$FORK_BRANCH is based on -- everything after it is treated as the fork's own \
work and replayed onto each release. Set it once, e.g.: \
echo 4eb5d723d627edec42ca3e5d606e1227c656dfca > $STATE/fork-base"
  fi

  local old_base
  old_base="$(tr -d '[:space:]' < "$STATE/fork-base")"

  cd "$SRC" || die "cannot enter $SRC"

  # Full fetch, never --depth=1. A shallow fetch grafts the tag in with no
  # history, so rebase cannot find a merge base for its three-way merges and
  # reports conflicts on commits that apply perfectly well. It also leaves a
  # .git/shallow in an otherwise complete clone, which affects later operations.
  git fetch upstream "refs/tags/$tag:refs/tags/$tag" \
    || die "could not fetch tag $tag"

  # Skip the whole thing when nothing that determines the result has changed.
  # Rebasing again would produce an identical tree, but only after resetting to
  # origin and rewriting every file that differs from the release tag -- twice.
  # The mtime churn alone forces a near-total rebuild, which on a retry after a
  # single target failed is pure waste.
  local origin_sha head_sha marker
  origin_sha="$(git rev-parse "origin/$FORK_BRANCH")"
  head_sha="$(git rev-parse HEAD 2>/dev/null || echo none)"
  marker="$tag $origin_sha $old_base $head_sha"

  if [ -f "$STATE/last-rebase" ] \
      && [ "$(cat "$STATE/last-rebase")" = "$marker" ]; then
    log "Tree already rebased onto $tag and unchanged since; skipping rebase"
    return 0
  fi

  # -f discards the certificates install_mar_cert wrote into the tree last
  # cycle; git rebase refuses to run with a dirty working tree.
  git checkout -f -B fork-build "origin/$FORK_BRANCH" || die "checkout failed"

  # A conflict means upstream changed code the patch series touches. Stop.
  # Shipping a half-merged download path is worse than shipping nothing.
  if ! git rebase --onto "refs/tags/$tag" "$old_base" fork-build; then
    git rebase --abort 2>/dev/null || true
    git checkout -f "origin/$FORK_BRANCH" 2>/dev/null || true
    rm -f "$STATE/last-rebase"
    return 1
  fi

  # Record what produced this tree so the next cycle can tell it is already
  # correct. HEAD is included so any manual change to the checkout invalidates
  # it rather than being silently kept.
  echo "$tag $origin_sha $old_base $(git rev-parse HEAD)" > "$STATE/last-rebase"

  # fork-base is deliberately NOT advanced to $tag.
  #
  # The branch is re-checked-out from origin every cycle and the rebase result
  # is never pushed, so origin/$FORK_BRANCH stays on its original base forever.
  # Advancing fork-base would desynchronise the two immediately: the next cycle
  # would compute its commit list as $tag..origin/$FORK_BRANCH, which is every
  # upstream commit that diverged since that tag plus the fork's own -- and
  # would try to replay all of it.
  #
  # Keeping fork-base fixed makes each cycle replay exactly the same fork
  # commits onto whatever tag is current. Idempotent, and nothing to push.
  # It only changes when the patch series itself is rebased onto a new base,
  # which is a human action.
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

build_target() {
  local target="$1"
  cd "$SRC" || die "cannot enter $SRC"

  export MOZCONFIG="$SRC/tools/fork/mozconfigs/$target"
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
  # target builds one for that target -- win64 produces a Windows executable.
  # Signing does not care about architecture, so the native build's copy is
  # reused for every subsequent target.
  if [ -z "${FORK_SIGNMAR:-}" ]; then
    local candidate="$FORK_OBJDIR/dist/bin/signmar"
    if [ -x "$candidate" ]; then
      # `|| rc=$?` rather than a bare call: signmar exits non-zero for a usage
      # message, so this would kill the script if `set -e` were ever added here.
      local rc=0
      "$candidate" -h >/dev/null 2>&1 || rc=$?
      if [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ]; then
        export FORK_SIGNMAR="$candidate"
        log "Using signmar from $target: $FORK_SIGNMAR"
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
  case "$target" in
    linux64) cp -f "$ARTIFACTS"/*.tar.xz "$dl_dir/" 2>/dev/null || true ;;
    win64)   cp -f "$ARTIFACTS"/*.zip "$dl_dir/" 2>/dev/null || true ;;
  esac
  sync

  # Staging is per target. A shared directory would be removed and rewritten by
  # whichever publish ran second, discarding the other's manifests.
  log "Publishing $target manifests"
  local staging="$WWW/.manifests-staging-$target"
  rm -rf "$staging"
  python3 "$SRC/tools/fork/gen_update_manifest.py" \
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
  ensure_source

  local last_built=""
  [ -f "$STATE/last-built" ] && last_built="$(tr -d '[:space:]' < "$STATE/last-built")"

  local check version tag should
  check="$(python3 "$SRC/tools/fork/check_release.py" \
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
  write_status "building" "rebasing onto $tag" "$version"

  if ! rebase_onto "$tag"; then
    notify "Rebase conflict on $tag: the onDeterminingFilename patches do not \
apply. No build was published for $version. Resolve it on $FORK_BRANCH and \
push; leave $STATE/fork-base alone unless you rebased the series onto a \
different upstream base. Reproduce it by hand with: git rebase --onto \
refs/tags/$tag \$(cat $STATE/fork-base) $FORK_BRANCH"
    write_status "conflict" "patch series does not apply to $tag" "$version"
    return 1
  fi

  check_url_consistency
  install_mar_cert
  ensure_bootstrap

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
    if ! "$SRC/tools/fork/make_mar.sh" "$target" \
        "$FORK_OBJDIR" "$ARTIFACTS"; then
      log "MAR packaging or signing failed for $target; continuing"
      failed="$failed $target"
      continue
    fi

    case "$target" in
      linux64) cp -f "$FORK_OBJDIR"/dist/*.tar.xz "$ARTIFACTS"/ 2>/dev/null || true ;;
      win64)   cp -f "$FORK_OBJDIR"/dist/*.zip "$ARTIFACTS"/ 2>/dev/null || true ;;
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
  check="$(python3 "$SRC/tools/fork/check_release.py" \
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

step_rebase() {
  step_should_skip && return 0
  local tag; tag="$(ci_get tag)"
  [ -n "$tag" ] || { log "no tag recorded; run detect first"; return 1; }

  if ! rebase_onto "$tag"; then
    notify "Rebase conflict on $tag: the onDeterminingFilename patches do not apply."
    write_status "conflict" "patch series does not apply to $tag" "$(ci_get version)"
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

  mkdir -p "$ARTIFACTS"
  "$SRC/tools/fork/make_mar.sh" "$target" "$objdir" "$ARTIFACTS" || return 1

  case "$target" in
    linux64) cp -f "$objdir"/dist/*.tar.xz "$ARTIFACTS"/ 2>/dev/null || true ;;
    win64)   cp -f "$objdir"/dist/*.zip "$ARTIFACTS"/ 2>/dev/null || true ;;
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
  notify "Published Firefox $version for:$built"
  write_status "ok" "published" "$version"
  return 0
}

run_step() {
  local cmd="${1:?usage: build-loop.sh step <detect|rebase|build|mar|publish|finalize> [target]}"
  shift
  case "$cmd" in
    detect)   step_detect "$@" ;;
    rebase)   step_rebase "$@" ;;
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

  # config.sh lives in the tree, so the clone has to come first. Values already
  # set in the environment by the compose file win over its defaults.
  ensure_source

  # This script is baked into the image, because it has to exist before there
  # is a checkout to run it from. Once the checkout exists, hand over to the
  # in-tree copy if it differs, so fixes to the loop take effect by updating
  # /src rather than rebuilding the image. The guard prevents an exec loop.
  local intree="$SRC/tools/fork/docker/build-loop.sh"
  if [ -z "${FORK_LOOP_REEXEC:-}" ] && [ -f "$intree" ] && ! cmp -s "$intree" "$0"; then
    log "In-tree build loop differs from the image copy; handing over to it"
    export FORK_LOOP_REEXEC=1
    exec bash "$intree" "$@"
  fi

  . "$SRC/tools/fork/config.sh" || die "could not source tools/fork/config.sh"

  preflight

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
