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
├── state/      toolchains, sccache, mar-nss/ (key + certs), markers (~50 GB)
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

Drop `win64` from `FORK_TARGETS` to skip this entirely and build linux64 only.

### 5. Seed the rebase base

The loop tracks what `ssm9/fork-build` currently sits on, so it knows which
commits are the fork's own when replaying them onto a new tag. It refuses to
start without this rather than guessing — rebasing from the wrong base would
silently produce a build with the wrong patches applied.

The branch was developed on **mozilla-central**, so the initial value is a
commit, not a release tag:

```sh
echo 4eb5d723d627edec42ca3e5d606e1227c656dfca \
  > /mnt/tank/firefox-fork/state/fork-base
```

After the first successful rebase the loop overwrites this with the release tag
it rebased onto, and it stays a tag from then on.

**Expect the first rebase to need attention.** The patch series was written
against central (154.0a1) and the build server targets release (153.0.1), which
is an older, divergent branch. Replaying 24 commits across that gap is exactly
the case the conflict guard exists for. If it stops, resolve the conflicts on
`ssm9/fork-build`, push, and set `fork-base` to the release tag by hand.

### 6. Install the app

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
/obj/obj-fork-linux64/dist/host/bin/signmar \
  -D toolkit/mozapps/update/updater/release_primary.der \
  -v /www/downloads/<version>/firefox-<version>.linux64.complete.mar
```

Manifest reachable at the exact path a client will ask for:

```sh
curl https://firefox-builds.sai.town/updates/Linux_x86_64-gcc3/ssm9/update.xml
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
