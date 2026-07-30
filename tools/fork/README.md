# Fork build pipeline

A self-hosted build server that rebuilds Firefox from each upstream release tag
with the `downloads.onDeterminingFilename` patch series applied, and serves the
resulting updates to its own builds.

Runs as a TrueNAS SCALE app (24.10 Electric Eel or newer, which uses Docker).

## Why it is built this way

Mozilla's updater only accepts MARs signed by keys compiled into the binary
(`toolkit/mozapps/update/updater/updater-common.build:18`). That rules out the
much cheaper approach of repacking official builds: the patch is pure JS inside
`omni.ja`, so swapping the files in works fine, but the first auto-update
replaces `omni.ja` wholesale and silently reverts the patch. Partial MARs fail
their source checksum against a modified file, and Firefox then falls back to a
complete MAR that overwrites everything.

Building from source is what lets us bake in our own signing key, which is what
lets updates work at all.

## Architecture

```
TrueNAS SCALE custom app
├── builder    polls upstream every 6h; on a new release, rebases the patch
│              series, builds, signs MARs, publishes into /www
└── web        nginx serving /www (manifests + MARs), on host port 8088

WireGuard client → nginx-proxy-manager → <nas-ip>:8088
```

Nothing is exposed to the public internet. Clients reach the update server
through the WireGuard tunnel, so builds keep updating away from the LAN.

## Scope

Builds **linux64** and **win64**, both cross-compiled from Linux.

macOS is deliberately not built. A MAR rewrites files inside the `.app`, so the
bundle must be signed *before* the MAR is generated or updated installs land
with a broken code-signing seal. Ad-hoc signing re-breaks that seal on every
update, so seamless macOS auto-update effectively requires Developer ID plus
notarization. Deferred until the chain is proven on the two platforms with no
signing complications.

## The URL is permanent

The update URL is compiled into every build. An install asks whichever URL it
was built with, forever. Changing it later strands every existing install on the
old address, with no way to migrate them short of a manual reinstall.

Use a DNS name, never a bare IP, and pick one that resolves **over the WireGuard
tunnel** and not only on the LAN. It has to be set identically in two places:

- `build/application.ini.in` — the `URL=` line
- `FORK_UPDATE_HOST` / `FORK_UPDATE_SCHEME` in the compose file

`build-loop.sh` parses the first and compares it to the second, and refuses to
build if they disagree. Scheme counts as much as hostname: a build compiled for
`https` but served over `http` will never find its manifest. That check exists
because a mismatch otherwise produces a perfectly good build that silently
never updates.

## One-time setup

### 1. nginx-proxy-manager and WireGuard

Add a proxy host in NPM:

| Field | Value |
| --- | --- |
| Domain | the name you will bake into builds, e.g. `firefox-updates.lan` |
| Scheme | `http` |
| Forward host | the NAS's LAN address |
| Forward port | `8088` (`WEB_PORT` in the compose file) |
| Cache Assets | **off** |
| Websockets | off |

**Leave "Cache Assets" off.** A cached `update.xml` means clients keep being
offered a version they already have, or one whose MARs have been replaced. The
origin already sends `Cache-Control: no-store` for manifests, but NPM's caching
does not always defer to it.

In the **Advanced** tab, add:

```nginx
proxy_buffering off;
```

MARs are 70–90 MB. With buffering on, NPM spools each download to disk before
sending it, which adds latency and disk churn for no benefit.

Then make sure the domain **resolves through the tunnel**. Either point the
WireGuard client's `DNS =` at your internal resolver, or add a DNS record that
resolves to the NPM address. `AllowedIPs` must cover the NPM host. If the name
only resolves on the LAN, updates silently stop the moment you leave the
network — which looks identical to "no update available".

### 2. MAR signing key

On any machine with `certutil` (Debian: `libnss3-tools`):

```sh
./tools/fork/gen_mar_key.sh
```

Writes an NSS database to `~/.ssm9-mar-nss` and the public certificate to
`toolkit/mozapps/update/updater/release_{primary,secondary}.der`. Commit the two
`.der` files, then copy the database onto the state volume:

```sh
cp -r ~/.ssm9-mar-nss /mnt/tank/firefox-fork/state/mar-nss
```

**Back it up offline before publishing any build.** An installed build only
accepts MARs signed by the key compiled into it. Losing the key means every user
reinstalls by hand; there is no recovery path.

### 3. Datasets

```
/mnt/tank/firefox-fork/
├── src/        git checkout          (~10 GB)
├── obj/        object directories    (~50 GB)
├── state/      toolchains, sccache, signing key, markers (~50 GB)
├── www/        published manifests and MARs
├── vs/         packaged MSVC toolchain (win64 only)
└── config/     nginx.conf from this directory
```

Copy `nginx.conf` into `config/`.

### 4. Windows toolchain

MSVC and the Windows SDK cannot be redistributed by Mozilla, so `vs/` needs a
copy packaged from a machine with Visual Studio installed. `build/vs/vs2026.yaml`
documents the component list and the `build/vs/generate_yaml.py` invocation that
produced it.

Leave `vs/` empty to build linux64 only — the loop logs and skips win64 rather
than failing the whole cycle.

### 5. Seed the rebase base

The loop tracks which upstream tag the fork branch sits on. Set it once to
whatever `ssm9/fork-build` is currently based on:

```sh
echo FIREFOX_153_0_1_RELEASE > /mnt/tank/firefox-fork/state/fork-base
```

It refuses to start without this rather than guessing, because rebasing onto the
wrong base would silently produce a build with the wrong patches applied.

### 6. Install the app

Apps > Discover Apps > Custom App > Install via YAML, using
`docker-compose.yaml` from this directory. Set `FORK_UPDATE_HOST`, `TS_AUTHKEY`,
and `TS_HOSTNAME`; optionally `BUILD_JOBS` and `NOTIFY_URL`.

Replace every `/mnt/tank/...` path with your real dataset paths.

## How a release flows

1. `check_release.py` finds the newest `FIREFOX_*_RELEASE` tag and compares it
   to `state/last-built`. Dot releases (`153.0.1`) count — those are the
   security updates, which is why the loop polls every 6h rather than monthly.
2. The fork branch is rebased onto the new tag. **A conflict stops the cycle
   and notifies.** Nothing is published. This is the guard against silently
   shipping a mis-merged download path when upstream touches the same code.
3. Each target builds, and `make_mar.sh` produces a signed complete MAR,
   verifying it against the committed certificate before it can be published.
4. MARs are copied into `/www/downloads/<version>/` **first**, and only then are
   the manifests written. A client checking in between sees the old manifest,
   never a new one pointing at a MAR that has not landed yet.
5. `state/last-built` is updated.

Progress is written to `/status.json`, served alongside the manifests.

## Resource notes

Firefox is a heavy build — expect hours on typical NAS hardware, and set
`BUILD_JOBS` below your core count if builds starve the NAS of CPU for its
actual job. The sccache on the state volume is what keeps release-to-release
rebuilds tolerable; do not put it on a tmpfs or wipe it between runs.

## Install location on Windows

Windows builds set `--disable-maintenance-service`, because the service refuses
to apply an update unless the binary passes an Authenticode check
(`toolkit/mozapps/update/common/registrycertificates.cpp:39`) that unsigned fork
builds can never pass.

Updates therefore run unelevated, as the invoking user, which means **Firefox
must be installed somewhere user-writable** — under `%LOCALAPPDATA%`, not
`Program Files`. Installed into `Program Files`, it will download updates and
then silently fail to apply them.

## Why plain HTTP

The updater has no HTTPS requirement — its own test harness runs against
`http://localhost` (`toolkit/mozapps/update/tests/data/xpcshellUtilsAUS.js:78`),
and there is no scheme check in `UpdateService.sys.mjs`. Integrity comes from
the MAR signature, not from the transport: an attacker who could rewrite
responses still cannot get a MAR installed without the signing key.

WireGuard already provides encryption and peer authentication for everything in
front of it, so TLS on top would be duplicating work that is already done, while
adding a certificate renewal that update delivery then depends on.

Terminating TLS at NPM with an internal CA would be actively worse than either
option: Firefox validates against NSS's own trust store rather than the OS one,
so an untrusted cert makes update checks fail with no visible error. If you ever
do want HTTPS here, use a publicly trusted certificate and set
`FORK_UPDATE_SCHEME=https` **before** the first build — the scheme is compiled
in and cannot be changed for installs already in the field.

## Verifying the chain

Do this by hand on linux64 before trusting the automation. `RUN_ONCE=1` makes
the builder do a single cycle and exit instead of looping.

Patch actually present in the build (this file does not exist in stock Firefox):

```sh
unzip -l /obj/obj-fork-linux64/dist/firefox/omni.ja \
  chrome/toolkit/content/extensions/child/ext-downloads.js
```

Existing test suite:

```sh
./mach test toolkit/components/extensions/test/xpcshell/test_ext_downloads_determining_filename.js
```

MAR signature against the compiled-in certificate:

```sh
/obj/obj-fork-linux64/dist/host/bin/signmar \
  -D toolkit/mozapps/update/updater/release_primary.der \
  -v /www/downloads/<version>/firefox-<version>.linux64.complete.mar
```

Manifest reachable at the exact path a client will ask for:

```sh
curl http://firefox-updates.lan/updates/Linux_x86_64-gcc3/ssm9/update.xml
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

## Extension signing

These builds set `MOZ_REQUIRE_SIGNING=`, so an unsigned extension loads once
`xpinstall.signatures.required` is `false`. Signing is only needed to make the
extension portable to stock Firefox elsewhere.

`.github/workflows/sign-extension.yml` does it on demand via `web-ext sign
--channel=unlisted`. Needs `AMO_JWT_ISSUER` / `AMO_JWT_SECRET` secrets and a
stable `browser_specific_settings.gecko.id` in the extension manifest.

## Known limitations

- **en-US only.** No l10n repacks.
- **Unofficial branding.** Firefox branding may not be used on modified builds.
- **Complete MARs only.** Every update is a full download; no partials.
- **No macOS** — see Scope above.
- **Clients must be on the WireGuard tunnel** to receive updates, and the
  update hostname must resolve through it.
