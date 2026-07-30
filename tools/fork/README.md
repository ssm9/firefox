# Fork build pipeline

Rebuilds Firefox from each upstream release tag with the
`downloads.onDeterminingFilename` patch series applied, and serves updates
signed with this fork's own MAR key.

## Why it is built this way

Mozilla's updater only accepts MARs signed by keys compiled into the binary
(`toolkit/mozapps/update/updater/updater-common.build:18`). That rules out the
much cheaper approach of repacking official builds: the patch is pure JS inside
`omni.ja`, so swapping the files in works fine, but the first auto-update
replaces `omni.ja` wholesale and silently reverts the patch. Partial MARs fail
their source checksum against a modified file, and Firefox then falls back to a
complete MAR that overwrites everything.

Building from source is what lets us bake in our own key, which is what lets
updates work at all.

## Scope

Currently builds **linux64** and **win64**, both cross-compiled from Linux.

macOS is deliberately not built yet. A MAR rewrites files inside the `.app`, so
the bundle must be signed *before* the MAR is generated or updated installs land
with a broken code-signing seal. Ad-hoc signing re-breaks that seal on every
update, so seamless macOS auto-update effectively requires Developer ID plus
notarization. That decision was deferred until the update chain is proven on the
two platforms that have no signing complications.

## One-time setup

### 1. MAR signing key

```sh
./tools/fork/gen_mar_key.sh
```

Writes an NSS database to `~/.ssm9-mar-nss` and the public certificate to
`toolkit/mozapps/update/updater/release_{primary,secondary}.der`. Commit the
two `.der` files.

**Back up `~/.ssm9-mar-nss` offline before publishing any build.** An installed
build only accepts MARs signed by the key compiled into it. Losing the key means
every user has to reinstall by hand; there is no recovery path.

Then store it for CI:

```sh
tar -C ~/.ssm9-mar-nss -cz . | base64 -w0
```

Set the result as the `FORK_MAR_NSS_DB` repository secret.

### 2. Windows toolchain

MSVC and the Windows SDK cannot be redistributed by Mozilla, so the build host
needs a copy you package yourself from a machine with Visual Studio installed.
`build/vs/vs2026.yaml` documents the exact component list and the
`build/vs/generate_yaml.py` invocation that produced it.

Make the unpacked toolchain available to the runner and confirm `./mach build`
picks it up before wiring the workflow — this is the step most likely to need
iteration on a real machine.

### 3. Self-hosted runner

Register a Linux machine against this repo as a self-hosted Actions runner, and
run `./mach bootstrap` once. Needs roughly 50 GB free for the two object
directories plus the sccache cache.

Install `sccache` and put it on `PATH`. The mozconfigs pick it up automatically
when present; a warm cache is what keeps release-to-release rebuilds tolerable
on one machine.

### 4. Update manifest host

Create a repo with GitHub Pages enabled — `ssm9/firefox-updates` by default,
matching the URL baked into `build/application.ini.in`. If you use a different
name, change it in **both** places (`build/application.ini.in` and
`tools/fork/config.sh`), or clients will request manifests that do not exist.

Create a token with write access to that repo and store it as the
`FORK_PAGES_TOKEN` secret.

### 5. Extension signing (optional)

Set the `EXTENSION_REPO` repository *variable* to the extension's repo, and add
`AMO_JWT_ISSUER` / `AMO_JWT_SECRET` secrets from your AMO account. The extension
needs a stable `browser_specific_settings.gecko.id` in its manifest.

The `sign-extension` job is skipped entirely while `EXTENSION_REPO` is unset.

Signing is not strictly required: these builds set `MOZ_REQUIRE_SIGNING=`, so an
unsigned extension loads once `xpinstall.signatures.required` is `false`. A
signed `.xpi` is just portable to other Firefox installs. Note the AMO linter
may warn about the unknown `onDeterminingFilename` API; for unlisted add-ons
that is a warning, not a rejection.

### 6. Bootstrap the rebase base

The workflow tracks which upstream tag the fork branch sits on via a
`refs/fork/base` ref, so nothing in the tree has to record it. Set it once to
whatever `ssm9/fork-build` is currently based on:

```sh
git update-ref refs/fork/base <current-upstream-base-sha>
git push origin refs/fork/base:refs/fork/base
```

## How a release flows

1. `check_release.py` finds the newest `FIREFOX_*_RELEASE` tag and compares it
   against the last published GitHub release. Dot releases (`153.0.1`) count —
   those are the security updates, so polling daily matters more than the
   4-week major cadence.
2. `ssm9/fork-build` is rebased onto the new tag. **A conflict stops the run and
   opens an issue.** Nothing is published. This is the guard against silently
   shipping a mis-merged download path when upstream touches the same code.
3. Both targets build, and `make_mar.sh` produces a signed complete MAR,
   verifying it against the committed certificate before it can be published.
4. A GitHub Release is created with the MARs and installers.
5. `gen_update_manifest.py` writes `update.xml` per `BUILD_TARGET` and pushes
   them to the Pages repo.

## Install location on Windows

Windows builds set `--disable-maintenance-service`, because the service refuses
to apply an update unless the binary passes an Authenticode check
(`toolkit/mozapps/update/common/registrycertificates.cpp:39`) that unsigned fork
builds can never pass.

Updates therefore run unelevated, as the invoking user, which means **Firefox
must be installed somewhere user-writable** — under `%LOCALAPPDATA%`, not
`Program Files`. Installed into `Program Files`, it will download updates and
then silently fail to apply them.

## Verifying the chain

Do this by hand on linux64 before trusting the automation.

Patch actually present in the build (this file does not exist in stock Firefox):

```sh
unzip -l obj-fork-linux64/dist/firefox/omni.ja \
  chrome/toolkit/content/extensions/child/ext-downloads.js
```

Existing test suite:

```sh
./mach test toolkit/components/extensions/test/xpcshell/test_ext_downloads_determining_filename.js
```

MAR signature against the compiled-in certificate:

```sh
obj-fork-linux64/dist/host/bin/signmar \
  -D toolkit/mozapps/update/updater/release_primary.der \
  -v artifacts/firefox-<version>.linux64.complete.mar
```

**The test that matters:** install release N, let it update to N+1, and confirm
the extension still routes downloads afterwards. That is precisely what fails on
the repack approach and the entire reason this pipeline exists — verify it
explicitly rather than assuming it.

`app.update.url` no longer exists as a pref, but the enterprise policy
`AppUpdateURL` still overrides the built-in URL
(`toolkit/mozapps/update/UpdateService.sys.mjs:5463`), which is useful for
pointing a test build at a scratch manifest without rebuilding.

## Rotating the signing key

The updater trusts two certificates so a key can be replaced without stranding
clients:

1. Put the new certificate in `release_secondary.der`, keep the old one in
   `release_primary.der`, and ship a release. Clients now trust both.
2. Once everyone has that build, start signing with the new key and move it to
   `release_primary.der`.

Skipping step 1 strands every client on the old key.

## Known limitations

- **en-US only.** No l10n repacks.
- **Unofficial branding.** Firefox branding may not be used on modified builds.
- **Complete MARs only.** Every update is a full download; no partials.
- **No macOS** yet — see Scope above.
