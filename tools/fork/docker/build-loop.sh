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
# are Mozilla's real release certificates. Building against those would produce
# installs that reject their own updates.
install_mar_cert() {
  local dest="$SRC/toolkit/mozapps/update/updater"
  local n

  for n in release_primary release_secondary; do
    if [ ! -s "$FORK_NSS_DIR/$n.der" ]; then
      die "Missing $FORK_NSS_DIR/$n.der. Generate the signing key with \
tools/fork/gen_mar_key.sh and put its output on the state volume."
    fi
    cp -f "$FORK_NSS_DIR/$n.der" "$dest/$n.der" || die "could not install $n.der"
  done

  log "Installed fork MAR certificates over upstream's"
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

  # Force, because install_mar_cert leaves the certificates modified in the
  # working tree. Without -f this fails from the second cycle onwards, and a
  # dirty tree would also make the rebase below refuse to start. Discarding is
  # safe: the certificates are reinstalled from the state volume every build.
  git checkout -f -B fork-build "origin/$FORK_BRANCH" \
    || die "could not check out $FORK_BRANCH"
}

ensure_bootstrap() {
  if [ -f "$STATE/.bootstrapped" ]; then
    return
  fi
  log "Running mach bootstrap (first run only)"
  cd "$SRC" || die "cannot enter $SRC"
  ./mach --no-interactive bootstrap --application-choice browser \
    || die "mach bootstrap failed"
  touch "$STATE/.bootstrapped"
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

  # -f discards the certificates install_mar_cert wrote into the tree last
  # cycle; git rebase refuses to run with a dirty working tree.
  git checkout -f -B fork-build "origin/$FORK_BRANCH" || die "checkout failed"

  # A conflict means upstream changed code the patch series touches. Stop.
  # Shipping a half-merged download path is worse than shipping nothing.
  if ! git rebase --onto "refs/tags/$tag" "$old_base" fork-build; then
    git rebase --abort 2>/dev/null || true
    git checkout -f "origin/$FORK_BRANCH" 2>/dev/null || true
    return 1
  fi

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
  export MOZ_OBJDIR="/obj/obj-fork-$target"
  [ -n "$BUILD_JOBS" ] && export MOZ_MAKE_FLAGS="-j$BUILD_JOBS"

  if [ ! -f "$MOZCONFIG" ]; then
    log "ERROR: no mozconfig at $MOZCONFIG"
    return 1
  fi

  if [ "$target" = "win64" ]; then
    ensure_vs || return 1
    # WINSYSROOT, not VSPATH: configure reads WINSYSROOT
    # (build/moz.configure/windows-toolchain.configure:62) and expects a
    # directory containing VC, "Windows Kits/10" and DIA SDK, which is what
    # get_vs.py produces. Setting it also stops configure trying to bootstrap
    # a "vs" toolchain, which is not publicly downloadable.
    export WINSYSROOT=/vs
  fi

  log "Building $target"
  ./mach build || return 1
  ./mach package || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------

publish() {
  local version="$1"
  shift
  local metadata=("$@")

  local dl_dir="$WWW/downloads/$version"
  mkdir -p "$dl_dir"

  # Order matters: the MARs must be downloadable *before* any manifest points
  # at them, or a client that checks in between sees a manifest referencing a
  # 404 and records a failed update.
  log "Publishing artifacts for $version"
  cp -f /tmp/fork-artifacts/*.mar "$dl_dir/" || return 1
  cp -f /tmp/fork-artifacts/*.tar.xz "$dl_dir/" 2>/dev/null || true
  cp -f /tmp/fork-artifacts/*.zip "$dl_dir/" 2>/dev/null || true
  sync

  log "Publishing manifests"
  local staging="$WWW/.manifests-staging"
  rm -rf "$staging"
  python3 "$SRC/tools/fork/gen_update_manifest.py" \
    --metadata "${metadata[@]}" \
    --outdir "$staging" \
    --channel "$FORK_CHANNEL" \
    --release-base-url "$FORK_DOWNLOAD_BASE_URL/$version" || return 1

  mkdir -p "$WWW/updates"
  cp -rf "$staging"/* "$WWW/updates/" || return 1
  rm -rf "$staging"
  sync
  return 0
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

  rm -rf /tmp/fork-artifacts
  mkdir -p /tmp/fork-artifacts

  local metadata=()
  local target
  for target in $FORK_TARGETS; do
    write_status "building" "compiling $target" "$version"
    if ! build_target "$target"; then
      notify "Build failed for $target on $version. Nothing published."
      write_status "failed" "build failed for $target" "$version"
      return 1
    fi

    if ! "$SRC/tools/fork/make_mar.sh" "$target" \
        "/obj/obj-fork-$target" /tmp/fork-artifacts; then
      notify "MAR packaging or signing failed for $target on $version."
      write_status "failed" "MAR packaging failed for $target" "$version"
      return 1
    fi

    case "$target" in
      linux64) cp -f "/obj/obj-fork-$target"/dist/*.tar.xz /tmp/fork-artifacts/ 2>/dev/null || true ;;
      win64)   cp -f "/obj/obj-fork-$target"/dist/*.zip /tmp/fork-artifacts/ 2>/dev/null || true ;;
    esac

    metadata+=("/tmp/fork-artifacts/$target.mar.json")
  done

  if ! publish "$version" "${metadata[@]}"; then
    notify "Publishing failed for $version; the previous version is still being served."
    write_status "failed" "publish failed" "$version"
    return 1
  fi

  echo "$version" > "$STATE/last-built"
  notify "Published Firefox $version for $FORK_TARGETS"
  write_status "ok" "published" "$version"
  return 0
}

# ---------------------------------------------------------------------------

main() {
  [ -d "$STATE" ] || die "/state is not mounted"
  [ -d "$WWW" ] || die "/www is not mounted"
  mkdir -p "$MOZBUILD_STATE_PATH" "$SCCACHE_DIR" /obj /src

  # config.sh lives in the tree, so the clone has to come first. Values already
  # set in the environment by the compose file win over its defaults.
  ensure_source
  . "$SRC/tools/fork/config.sh" || die "could not source tools/fork/config.sh"

  preflight

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
