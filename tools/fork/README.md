# Fork build pipeline

A self-hosted build server that rebuilds Firefox from each upstream release tag
with the `downloads.onDeterminingFilename` patch series applied, and serves the
resulting updates to its own builds.

Runs as a TrueNAS SCALE app (24.10 Electric Eel or newer, which uses Docker).

**To stand it up, follow [DEPLOY.md](DEPLOY.md).** This file covers what the
pieces are and why they work the way they do.

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
├── builder    polls upstream every 6h; on a new release, cherry-picks the
│              patch series, builds, signs MARs, publishes into /www
└── web        nginx serving /www (manifests, MARs, install scripts), on host
               port 8088

WireGuard client → nginx-proxy-manager → <nas-ip>:8088
```

Nothing is exposed to the public internet. Clients reach the update server
through the WireGuard tunnel, so builds keep updating away from the LAN.

## Scope

Builds **linux64**, **win64** and **macos-aarch64**, all cross-compiled from
Linux. No Windows machine and no Mac is involved in producing any of them.

macOS is Apple Silicon only, and a single-architecture build rather than a
universal binary. Intel Macs are not covered: Rosetta translates x86_64 to
arm64 and not the reverse, so nothing here runs on one. Adding an x86_64 target
is a second mozconfig and an entry in `FORK_TARGETS`; it is left out because it
would add a third full Firefox compile per release for hardware Apple stopped
selling in 2020.

### What macOS code signing does and does not affect

These builds carry no Developer ID signature and are not notarized. That is
worth being precise about, because it is easy to assume it breaks auto-update.
It does not.

- *Updates.* Nothing in the update path checks the application's signature.
  MAR verification on macOS goes through `SecVerifyTransform` against the public
  key of the certificate compiled into the updater, with no trust evaluation
  (`modules/libmar/verify/MacVerifyCrypto.cpp`) — the same guarantee the NSS
  path gives on Linux. The Windows equivalent, the maintenance service's
  Authenticode check, has no counterpart here.
- *Launching.* Apple Silicon requires every executable to carry a signature,
  but an ad-hoc one satisfies it, and lld attaches one to each Mach-O as it
  links. A complete MAR replaces those files byte for byte, so an update
  cannot invalidate what it did not modify. There is no bundle-level
  `_CodeSignature` to fall out of step with the files, precisely because the
  bundle is unsigned.
- *Gatekeeper.* This is what the absence of a signature does cost. A bundle
  downloaded through a browser is flagged with `com.apple.quarantine`, and an
  unsigned quarantined bundle is refused outright — reported, unhelpfully, as
  the application being damaged. `install-macos.sh` clears the flag.
- *Elevation.* Not a signing problem, but it becomes one if the install lands
  in the wrong place. See "Install location on macOS" below.

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
| Domain | `firefox-builds.sai.town` |
| Scheme | `http` (this is NPM → container; TLS terminates at NPM) |
| Forward host | the NAS's LAN address |
| Forward port | `8088` (`WEB_PORT` in the compose file) |
| Cache Assets | **off** |
| Websockets | off |

On the **SSL** tab, select an existing **wildcard** certificate for the parent
domain and enable **Force SSL**.

Use a wildcard rather than a per-host certificate. Let's Encrypt publishes
everything it issues to public Certificate Transparency logs, so a certificate
naming `firefox-builds.sai.town` makes that hostname permanently and publicly
searchable. A wildcard reveals only `*.sai.town`.

The certificate must be publicly trusted — Firefox validates against NSS's own
trust store, not the OS one, so an internal CA would make update checks fail
with no visible error. It also means **certificate renewal is now a dependency
of updates working**: if renewal lapses, clients stop updating silently. Worth
a calendar reminder or an alert on the NPM cert expiry.

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

The certificate compiled into the updater decides which MARs an install will
accept. Upstream ships Mozilla's real release certificates in
`toolkit/mozapps/update/updater/release_*.der`; the build loop copies yours over
them after every rebase. They are **not** committed — that keeps per-deployment
material out of the branch, avoids binary conflicts on rebase, and avoids the
ordering problem where the builder would have to clone a branch already
containing a certificate for a key that does not exist yet.

Easiest place to generate them is the builder container itself, which already
has `certutil`. After the app is installed and has cloned the source:

```sh
sudo docker exec -it firefox-fork-builder bash -c \
  'FORK_NSS_DIR=/state/mar-nss /src/firefox/tools/fork/gen_mar_key.sh'
```

That writes the key and both `.der` files straight onto the state volume where
the loop expects them. The loop refuses to start until they are there.

**Back it up offline before publishing any build:**

```sh
tar -czf mar-nss-backup.tar.gz -C /mnt/tank/firefox-fork/state mar-nss
```

An installed build only accepts MARs signed by the key compiled into it. Losing
the key means every user reinstalls by hand; there is no recovery path.

### 3. Datasets

```
/mnt/tank/firefox-fork/
├── src/        git checkout          (~10 GB)
├── obj/        object directories    (~50 GB)
├── state/      toolchains, sccache, mar-nss/ (key + certs), markers (~55 GB)
│              also where the macOS SDK lands, under mozbuild/
├── www/        published manifests and MARs
├── vs/         MSVC toolchain, downloaded on first run (~15 GB, win64 only)
└── config/     nginx.conf from this directory
```

Copy `nginx.conf` into `config/`.

### 4. Windows toolchain

Nothing to do — leave `vs/` empty and the builder populates it on first run.

MSVC and the Windows SDK cannot be redistributed by Mozilla, but they can be
fetched from Microsoft directly on Linux: `vsdownload` is vendored at
`third_party/python/vsdownload`, and `taskcluster/scripts/misc/get_vs.py`
handles the non-Windows extraction layout, lowercasing paths and emitting a
clang VFS overlay for the case-insensitive headers. No Windows machine and no
Visual Studio install is involved.

If you ever need to do it by hand:

```sh
./mach python --virtualenv build \
  taskcluster/scripts/misc/get_vs.py build/vs/vs2026.yaml /vs
```

It is a several-GB download, done once. Fetching it means accepting Microsoft's
Build Tools licence terms.

Drop `win64` from `FORK_TARGETS` to skip this entirely.

### 5. macOS SDK

Nothing to do, and nothing to mount — unlike MSVC this needs no dataset of its
own.

Apple's SDK ships inside the Command Line Tools package, which Apple serves
publicly from `swcdn.apple.com`. `configure` resolves it through
`bootstrap_path("MacOSX26.5.sdk")`
(`build/moz.configure/toolchain.configure:260`), and because that toolchain's
CI artifact is private, bootstrap falls back to running `unpack-sdk.py` locally
(`build/moz.configure/bootstrap.configure:234`) — which downloads the package,
checks it against the SHA-512 recorded in
`taskcluster/kinds/toolchain/macos-sdk.yml`, and unpacks it under
`MOZBUILD_STATE_PATH` on the state volume. That is pure Python; no Xcode, no
Mac, no Apple ID.

Fetching it means accepting Apple's SDK licence terms.

The linker is clang's own lld, which emits Mach-O directly
(`build/moz.configure/toolchain.configure:1674`), so unlike Mozilla's own cross
builds there is no cctools to install. `llvm-ar`, `llvm-strip`,
`llvm-install-name-tool` and the rest come from the bootstrapped clang.

Drop `macos-aarch64` from `FORK_TARGETS` to skip the download.

### 6. Patch base

Nothing to configure. The build server derives where the fork's own commits
begin, as the merge base of the fork branch and `origin/main`.

The fork's changes are applied to each release tag as a single squashed commit,
cherry-picked onto the tag, rather than by replaying the commit series. The
history is worth keeping on the upstreamable branch, but the build only needs
the resulting tree, and squashing gives one conflict surface instead of one per
commit. It also keeps the checkout anchored to a release tag: moving between
releases touches a few hundred files where resetting to the
mozilla-central-based branch and rebasing forward touched over twelve thousand,
which is the difference between an incremental rebuild and a near-total one.

**Cherry-pick, not `git apply`.** This used to apply a squashed *diff* with
`git apply --3way`. That matches patches to files by path and has no rename
detection, so an upstream move of a file the series touches failed with
`<path>: does not exist in index` — even when the change itself still applied
cleanly — and rolled the whole apply back, leaving a pristine tree and no
conflict markers to work from. Going through the merge machinery instead
follows the rename and applies the change at the file's new path. That matters
because it is not hypothetical: the `.jsm` → `.sys.mjs` migration renamed three
of the files this series edits.

Rename detection is why `merge.renameLimit` and `diff.renameLimit` are set on
the checkout. Past the limit git silently stops looking for renames and prints
a warning, which would put the old behaviour back; a release-to-release diff of
mozilla-central is large enough to hit the defaults.

`test_apply.sh` covers this against synthetic upstream renames, deletions and
conflicts. It needs only git — no container, no Firefox checkout, no network —
and it extracts the functions from `build-loop.sh` rather than reimplementing
them, so it cannot drift:

```sh
tools/fork/test_apply.sh
```

Override the base only for a series based somewhere the merge base cannot
express:

```sh
echo <upstream-commit> > /mnt/tank/firefox-fork/state/fork-base
```

### 7. Install the app

Apps > Discover Apps > Custom App > Install via YAML, using
`docker-compose.yaml` from this directory.

`FORK_UPDATE_HOST` and `FORK_UPDATE_SCHEME` default to the values compiled into
`build/application.ini.in`, so they only need setting if you change the URL.
Optionally set `WEB_PORT`, `BUILD_JOBS`, and `NOTIFY_URL`.

Replace every `/mnt/tank/...` path with your real dataset paths.

## How a release flows

1. `check_release.py` finds the newest `FIREFOX_*_RELEASE` tag and compares it
   to `state/last-built`. Dot releases (`153.0.1`) count — those are the
   security updates, which is why the loop polls every 6h rather than monthly.
2. The fork branch is squashed into one commit and cherry-picked onto the new
   tag. **A conflict stops the cycle and notifies.** Nothing is published. This
   is the guard against silently shipping a mis-merged download path when
   upstream touches the same code.
3. Each target builds, and `make_mar.sh` produces a signed complete MAR,
   verifying it against the committed certificate before it can be published.
4. MARs are copied into `/www/downloads/<version>/` **first**, and only then are
   the manifests written. A client checking in between sees the old manifest,
   never a new one pointing at a MAR that has not landed yet.
5. `state/last-built` is updated.

Progress is written to `/status.json`, served alongside the manifests.

### The build ID exists twice, and both copies have to agree

`buildid.h` is stamped with the wall-clock time every time it is regenerated,
and it is regenerated more than once per cycle — packaging re-runs it after the
compile is over. A finished build therefore carries the build ID in two places:
in `application.ini`, and compiled into the launcher as `application.ini.h`
(`build/moz.build:122`). `appinfo.appBuildID` — what `about:support` shows, and
what the update service compares against the manifest — is read from the
compiled-in copy and never from the file, while `make_mar.sh` reads the file.

When those two drift apart, the manifest advertises a build ID no install can
ever report: the update downloads, applies, and the next check offers the same
update again, forever. `build-loop.sh` pins `MOZ_BUILD_DATE` for the whole cycle
so the value cannot move, and `make_mar.sh` refuses to package a build whose
launcher does not contain the build ID its `application.ini` claims.

Installs already stuck in that loop recover on their own once one consistent
build is published; they are not left behind.

### What is kept, and for how long

A published release costs about 575 MB under `/www/downloads/<version>/` —
three installers, three complete MARs and the Windows xpt archive — and
upstream ships one every few weeks. Keeping all of them adds something like
12 GB a year for builds nothing can be served from.

`FORK_KEEP_RELEASES` (default 3) caps it. After a fully successful cycle the
loop deletes the oldest directories beyond that, skipping any version a
manifest still points at: when one target fails, its manifest keeps advertising
the last release that built, so the newest directory is not necessarily the
only one in use. Set it to `0` to keep everything.

Nothing needs the older directories to construct an update — only complete MARs
are produced and the manifest names exactly one of them. They exist so a fresh
install of a recent release is still possible.

## Resource notes

Firefox is a heavy build — expect hours on typical NAS hardware, and set
`BUILD_JOBS` below your core count if builds starve the NAS of CPU for its
actual job. The sccache on the state volume is what keeps release-to-release
rebuilds tolerable; do not put it on a tmpfs or wipe it between runs.

## Installing a build

The install scripts are served by the same nginx that serves the updates, under
`/install/`, and the build loop copies them out of the tooling checkout on every
cycle. A client therefore needs one hostname and no copy of this repository:

```sh
# Linux
curl -O https://firefox-builds.sai.town/downloads/<version>/firefox-<version>.en-US.linux-x86_64.tar.xz
curl -O https://firefox-builds.sai.town/install/install-linux.sh
bash install-linux.sh firefox-<version>.en-US.linux-x86_64.tar.xz

# macOS
curl -O https://firefox-builds.sai.town/downloads/<version>/firefox-<version>.en-US.mac-aarch64.tar.gz
curl -O https://firefox-builds.sai.town/install/install-macos.sh
bash install-macos.sh firefox-<version>.en-US.mac-aarch64.tar.gz
```

Browse `/downloads/` for the current version. The scripts are served uncached and
as `text/plain`, so they can be read before being run and never lag behind the
branch the builds came from.

Windows has no script — unpack the zip under `%LOCALAPPDATA%`. Both scripts
install under the user's home directory for the reasons below.

### After the first install

Two `about:config` settings, per profile rather than per update:

- `xpinstall.signatures.required` → `false`, to load an unsigned extension.
- `browser.download.force_save_internally_handled_attachments` → `false`. It
  already defaults to false, but a profile carrying it as true force-saves any
  internally-handled attachment — a PDF served as `Content-Disposition:
  attachment` — straight to disk with `action = saveToDisk` and `alwaysAsk =
  false` (`uriloader/exthandler/nsExternalHelperAppService.cpp:1881`). That
  path skips the helper-app dialog, which is where the patch fires
  `onDeterminingFilename`, so the extension never gets to name the file.

## Install location on Windows

Windows builds set `--disable-maintenance-service`, because the service refuses
to apply an update unless the binary passes an Authenticode check
(`toolkit/mozapps/update/common/registrycertificates.cpp:39`) that unsigned fork
builds can never pass.

Updates therefore run unelevated, as the invoking user, which means **Firefox
must be installed somewhere user-writable** — under `%LOCALAPPDATA%`, not
`Program Files`. Installed into `Program Files`, it will download updates and
then silently fail to apply them.

## Install location on macOS

Same rule, different mechanism. Firefox decides whether an update needs
elevation purely by testing whether the install directory is writable by the
user running it (`toolkit/xre/nsUpdateDriver.cpp:451`). Install under
`~/Applications` and that test passes, so updates apply silently in place.

Install into `/Applications` and it depends on who owns the bundle. Owned by
you, it still works; owned by anyone else, every update raises an administrator
prompt — and that path runs through a privileged helper which checks the caller
against a code signing requirement that an unsigned build cannot meet.

`install-macos.sh` unpacks into `~/Applications` for that reason, and clears
`com.apple.quarantine` so Gatekeeper does not refuse the unsigned bundle. The
equivalent by hand:

```sh
tar -xf firefox-<version>.en-US.mac-aarch64.tar.gz
mv firefox/*.app ~/Applications/
xattr -dr com.apple.quarantine ~/Applications/*.app
```

The bundle is named for the branding's display name, so unofficial branding
produces `Nightly.app` rather than `Firefox.app`. That is cosmetic, and it
keeps the install from colliding with a real Firefox in the same directory.

## On the transport

Updates are served over HTTPS with a publicly trusted Let's Encrypt certificate
terminated at NPM. The origin behind it is plain HTTP on the LAN, which is fine
— nothing between NPM and the container leaves the machine.

Worth knowing what this does and does not buy, because it is easy to assume TLS
is what makes updates safe. It is not: integrity comes from the MAR signature.
The updater has no HTTPS requirement at all — its own test harness runs against
`http://localhost` (`toolkit/mozapps/update/tests/data/xpcshellUtilsAUS.js:78`),
and there is no scheme check in `UpdateService.sys.mjs`. An attacker who could
rewrite responses still could not get a MAR installed without the signing key.

What TLS adds here is that update checks keep working from outside the WireGuard
tunnel, and that nothing on the path can see or redirect them.

What it costs is a dependency: **if the certificate lapses, clients stop
updating, silently**. That is the main new failure mode introduced by this
choice, and it is why the certificate must be publicly trusted rather than an
internal CA — Firefox validates against NSS's own trust store, not the OS one,
so an untrusted certificate fails checks with no visible error.

The scheme is compiled into every build and cannot be changed for installs
already in the field.

## What discloses the hostname

Worth being precise about, since the update host is infrastructure you may not
want enumerable.

**Does not disclose it:**

- *The MAR signing certificate.* Subject is `CN=ssm9-mar,O=ssm9 firefox fork`
  with no hostname and no SAN. It is self-signed, never submitted to a CA, and
  never leaves the state volume.
- *A wildcard TLS certificate.* Certificate Transparency records `*.sai.town`
  and nothing about which subdomains exist.

**Does disclose it:**

- *A per-host TLS certificate.* Every certificate a public CA issues is
  published to CT logs and is searchable within minutes, permanently. This is
  why the setup uses a wildcard.
- *A public DNS record.* If the name resolves on the public internet it is
  visible to anyone who queries it, and subdomain enumeration tools try common
  names. Split-horizon DNS that only answers inside the tunnel avoids this.
- *Any build you hand to someone else.* The update URL is compiled into
  `application.ini`, so anyone with a copy of the binary can read it. This is
  unavoidable given the design — the build has to know where to look.

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
# signmar's -D DERFilePath form is compiled out on Linux (MAR_NSS is always
# defined there), so verification goes through a throwaway NSS database
# holding the certificate that is compiled into the updater.
sudo docker exec -it firefox-fork-builder bash -c '
  OBJ=/src/firefox/obj-x86_64-pc-linux-gnu
  DB=$(mktemp -d); PW=$(mktemp); printf "\n" > "$PW"
  certutil -N -d "$DB" -f "$PW"
  certutil -A -d "$DB" -f "$PW" -n forkverify -t ",," \
    -i /state/mar-nss/release_primary.der
  $OBJ/dist/bin/signmar -d "$DB" -n forkverify -v \
    /www/downloads/<version>/firefox-<version>.linux64.complete.mar
  rm -rf "$DB" "$PW"
'
```

The same command verifies the win64 and macos-aarch64 MARs — point it at their
files. Signature checking does not care which architecture the MAR was built
for, and the linux64 `signmar` is the only one that runs on the builder anyway.

Manifest reachable at the exact path a client will ask for, one per target:

```sh
curl https://firefox-builds.sai.town/updates/Linux_x86_64-gcc3/ssm9/update.xml
curl https://firefox-builds.sai.town/updates/WINNT_x86_64-msvc-x64/ssm9/update.xml
curl https://firefox-builds.sai.town/updates/Darwin_aarch64-gcc3/ssm9/update.xml
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
- **macOS is Apple Silicon only**, and the bundle is unsigned and not
  notarized — see Scope above. First install needs `install-macos.sh`, or the
  quarantine flag cleared by hand.
- **Clients must be on the WireGuard tunnel** to receive updates, and the
  update hostname must resolve through it.
