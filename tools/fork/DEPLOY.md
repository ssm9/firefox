# Deployment runbook

Linear steps to stand the build server up on TrueNAS SCALE 24.10+. For *why*
any of it works this way, see [README.md](README.md).

Values assumed throughout — adjust if yours differ:

| | |
| --- | --- |
| Pool path | `/mnt/tank/firefox-fork` |
| Update URL | `https://firefox-builds.sai.town` |
| Origin port | `8088` |
| Fork branch | `ssm9/fork-build` |
| Targets | `linux64 win64` |

Budget about **130 GB**: ~10 GB source, ~50 GB object dirs, ~40 GB sccache,
~15 GB MSVC toolchain, plus published artifacts.

## Before you start: `docker` needs `sudo`

TrueNAS restricts `/var/run/docker.sock` to root, so plain `docker` gives:

```
permission denied while trying to connect to the Docker daemon socket
```

Every `docker` command below is written with `sudo` for that reason.

Do **not** work around it by adding yourself to the `docker` group. It does not
apply reliably on SCALE, and TrueNAS is an appliance whose system state is
managed by middleware — hand-edited group membership does not survive updates,
so you would be back here after the next one.

Depending on how the datasets were created, `mkdir`, `git clone`, and `tar`
below may need `sudo` too. If you hit "permission denied" on a file operation
rather than on Docker, that is why.

---

## 1. Create the datasets

In the TrueNAS UI, or over SSH:

```sh
mkdir -p /mnt/tank/firefox-fork/{src,obj,state,www,vs,config}
```

If you are running the Woodpecker stack, it needs two more, and they must be
writable by the containers' own user — the server stores its SQLite database in
the first, and refuses to start if it cannot create it:

```sh
mkdir -p /mnt/tank/firefox-fork/{woodpecker,woodpecker-agent}

# The images run as a non-root user; find it and hand the directories over.
uid=$(sudo docker run --rm --entrypoint id woodpeckerci/woodpecker-server:v3 -u)
sudo chown -R "$uid" /mnt/tank/firefox-fork/woodpecker \
                     /mnt/tank/firefox-fork/woodpecker-agent
```

Docker creates a missing bind-mount source itself, but as root, which is why
this surfaces as `unable to open database file: no such file or directory`
rather than a permission error.

## 2. Get the config files onto the NAS

The builder clones the full source itself, so this is only to obtain
`nginx.conf` and `docker-compose.yaml`. A blobless sparse clone keeps it to
about 86 MB instead of several gigabytes:

```sh
cd /mnt/tank/firefox-fork
git clone --filter=blob:none --sparse --depth=1 \
  --branch ssm9/fork-build \
  https://github.com/ssm9/firefox.git fork-config
cd fork-config
git sparse-checkout set tools/fork/docker
```

Put the nginx config where the stack expects it:

```sh
cp tools/fork/docker/nginx.conf /mnt/tank/firefox-fork/config/
```

## 3. Build the builder image

TrueNAS's YAML installer pulls images rather than building them, so build it
once by hand. The tag must match what the compose file references.

```sh
cd /mnt/tank/firefox-fork/fork-config/tools/fork/docker
sudo docker build -t firefox-fork-builder:latest .
```

Confirm it exists:

```sh
sudo docker images firefox-fork-builder
```

## 4. Patch base — nothing to do

The build server derives where the fork's own commits begin, as the merge base
of the fork branch and `origin/main`. No seeding step.

Override it only for a series based somewhere the merge base cannot express:

```sh
echo <upstream-commit> > /mnt/tank/firefox-fork/state/fork-base
```

## 5. Install the app

Apps → Discover Apps → Custom App → **Install via YAML**.

Paste the contents of
`/mnt/tank/firefox-fork/fork-config/tools/fork/docker/docker-compose.yaml`.

Optional environment overrides:

- `BUILD_JOBS` — cap parallelism so builds do not eat every core
- `NOTIFY_URL` — any URL accepting a POST body, e.g. an ntfy topic
- `WEB_PORT` — if 8088 clashes
- `FORK_TARGETS` — set to `linux64` to skip Windows for now

It will start, clone the source into `/src` (slow — it is a large repo), and
then stop with a fatal error about the missing signing key. **That is
expected**; the key does not exist yet.

Watch it get that far:

```sh
sudo docker logs -f firefox-fork-builder
```

## 6. Generate the MAR signing key

Now that the source is cloned, generate the key inside the builder, which
already has `certutil`:

```sh
sudo docker exec -it firefox-fork-builder bash -c \
  'FORK_NSS_DIR=/state/mar-nss /src/firefox/tools/fork/gen_mar_key.sh'
```

This writes the private key and both `.der` certificates onto the state volume.
Nothing is committed to git — the loop installs the certificates over
upstream's before each build.

**Back it up now, off the NAS:**

```sh
tar -czf mar-nss-backup.tar.gz -C /mnt/tank/firefox-fork/state mar-nss
```

An installed build only accepts MARs signed by the key compiled into it. If you
lose this, every install has to be replaced by hand. There is no recovery path.

Restart the app so the loop picks it up:

```sh
sudo docker restart firefox-fork-builder
```

## 7. Configure nginx-proxy-manager

Add a proxy host:

| Field | Value |
| --- | --- |
| Domain | `firefox-builds.sai.town` |
| Scheme | `http` (NPM → container; TLS terminates at NPM) |
| Forward host | the NAS's LAN address |
| Forward port | `8088` |
| Cache Assets | **off** |
| Block Common Exploits | on |
| Websockets | off |

**SSL tab:** select your existing **wildcard** certificate for the parent
domain. Enable **Force SSL**.

Do not request a per-host certificate here. Let's Encrypt publishes every
certificate it issues to public Certificate Transparency logs, so a cert for
`firefox-builds.sai.town` puts that exact hostname in a permanent, publicly
searchable record within minutes of issuance. A wildcard shows only `*.sai.town`
in CT and says nothing about which subdomains exist.

**Advanced tab:**

```nginx
proxy_buffering off;
```

Two of these matter more than they look:

- **Cache Assets off** — a cached `update.xml` means clients keep being offered
  a version they already have.
- **proxy_buffering off** — MARs are 70–90 MB; with buffering on, NPM spools
  each one to disk before sending it.

## 8. Make the name resolve over WireGuard

Point the WireGuard client's `DNS =` at your internal resolver, or add a DNS
record resolving `firefox-builds.sai.town` to the NPM address. `AllowedIPs`
must cover the NPM host.

Verify **from a WireGuard client, not the LAN**:

```sh
curl https://firefox-builds.sai.town/status.json
```

If this only works on the LAN, updates stop the moment you leave the network —
and that failure looks exactly like "no update available".

## 9. First build

Just start the app. The loop runs a cycle immediately on startup and only then
sleeps until the next poll, so starting it *is* triggering the first build —
there is nothing extra to kick off.

Start it from the TrueNAS UI, or:

```sh
sudo docker start firefox-fork-builder
sudo docker logs -f firefox-fork-builder
```

Detaching from `docker logs` does not stop the build; the container keeps
running. Reattach any time with the same command.

> **Do not run a second one-off container to "watch" the build.** It would share
> `/obj` and `/www` with the app's container, and two builds writing the same
> object directory corrupt each other. It would also die the moment your SSH
> session drops, which for a multi-hour build is a near certainty.
>
> `RUN_ONCE=1` exists for debugging a single cycle, but only ever with the app
> container stopped first, and ideally detached (`-d`) rather than `-it` so a
> dropped connection does not kill it.

Confirm exactly one builder is running:

```sh
sudo docker ps --filter name=firefox-fork
```

The first run does a lot of one-time work: `mach bootstrap` fetches toolchains,
and if `win64` is in `FORK_TARGETS` it downloads the MSVC toolchain from
Microsoft (several GB). Then it compiles Firefox, which takes hours with a cold
sccache.

**If the patch does not apply**, upstream changed code the series touches. The
conflict markers are left in `/src/firefox` for inspection, and nothing is
published. Resolve it on `ssm9/fork-build` and push; the next cycle regenerates
the patch from the branch. Reproduce it by hand with:

```sh
sudo docker exec -it firefox-fork-builder \
  git -C /src/firefox apply --3way /state/fork.patch
```

Two checkouts live under `/src`:

- `/src/firefox` — the Firefox tree, kept at a release tag with the fork patch
  applied on top. Moving between releases touches a few hundred files, so
  rebuilds stay incremental.
- `/src/fork-tools` — a sparse checkout of `tools/fork` and `.woodpecker`, a
  few megabytes. Updating tooling does not touch the Firefox tree at all.

## 10. Verify before trusting it

Confirm the patch actually reached the build:

```sh
sudo docker exec firefox-fork-builder \
  /src/firefox/tools/fork/verify_patch.sh \
  /src/firefox/obj-x86_64-pc-linux-gnu
```

This extracts all eight patched files from `omni.ja` and compares them
byte-for-byte against the source they were built from — catching a stale
`omni.ja` or a `jar.mn` entry that silently failed to package a file, which
grepping for a marker would not. It also checks two things independent of the
source tree: that `child/ext-downloads.js` exists at all (it does not in stock
Firefox) and that the schema declares `onDeterminingFilename`.

Exit status is non-zero on any failure, so it can gate a release.

MAR signature against the certificate compiled into the updater:

```sh
# signmar's -D DERFilePath form is compiled out on Linux (MAR_NSS is always
# defined there), so verification goes through a throwaway NSS database
# holding the certificate that is compiled into the updater.
#
# The certificate comes from /state/mar-nss, never from the source tree. For a
# custom update channel the build reads dep1.der rather than release_primary.der
# (toolkit/mozapps/update/updater/moz.build:66), so install_mar_cert writes
# there and the tree's release_primary.der stays Mozilla's for good. Verifying
# against it fails with "Error verifying signature", which looks alarming and
# means nothing.
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

Manifest at the exact path a client asks for:

```sh
curl https://firefox-builds.sai.town/updates/Linux_x86_64-gcc3/ssm9/update.xml
```

**The test that actually matters:** install the published build, wait for the
next release to be built, let it auto-update, and confirm the extension still
routes downloads afterwards. Everything else can pass while this fails, and
this is the entire reason the pipeline exists.

## Optional: run it under Woodpecker CI

The polling loop works, but gives no per-step timing, no history, and no way to
retry one target without redoing the cycle. `docker-compose.woodpecker.yaml`
runs Woodpecker on the NAS instead, driving the same code: every step is
`build-loop.sh step <phase>`, so the loop and the pipeline cannot drift apart.

Compute stays local, so this costs nothing beyond the NAS.

`docker-compose.woodpecker.yaml` **replaces** `docker-compose.yaml` rather than
sitting beside it. It carries the same nginx service; the only thing it drops is
the polling loop, which the pipeline replaces. Running both would put two
builders on the same object directories and two nginx containers on one port.

1. Create a GitHub OAuth app (Settings > Developer settings > OAuth Apps) with
   callback `https://<woodpecker-host>/authorize`.
2. Generate an agent secret: `openssl rand -hex 32`.
3. Delete the existing custom app, then install
   `docker-compose.woodpecker.yaml` in its place, setting `WOODPECKER_HOST`,
   the OAuth client and secret, `WOODPECKER_ADMIN` (your GitHub username),
   `WOODPECKER_AGENT_SECRET`, and `BUILD_JOBS` at roughly half the core count.
4. Proxy the Woodpecker port through nginx-proxy-manager, as a second proxy
   host alongside the update server.
5. In the Woodpecker UI, enable the `ssm9/firefox` repository, mark it
   **trusted** (the pipeline mounts host paths), and add a cron trigger every
   6 hours.

**Set the branch to `ssm9/fork-build`**, on the cron and on manual runs. The
repository's default branch is upstream's `main`, which contains no
`.woodpecker/` directory, so a run against it finds no pipeline and does
nothing.

Deleting and reinstalling the app touches no state: everything durable lives on
the dataset, and the containers are disposable.

The pipeline is `.woodpecker/firefox-fork.yaml`:

```
detect → patch ─┬→ build-linux64 → publish-linux64 ─┬→ finalize
                └→ build-win64   → publish-win64   ─┘
```

The two targets build concurrently and each publishes as soon as it is ready,
so a slow or failing win64 no longer holds up a finished linux64. Both build
steps are `failure: ignore`; `finalize` owns `last-built` and is the step whose
colour reflects the run.

**Set `BUILD_JOBS` to about half the core count** when both targets build at
once. Unset, each build sizes itself for the whole machine, and two together
oversubscribe the CPU and can coincide at peak memory — two `libxul` links at
once is the likeliest way to exhaust RAM. To go back to sequential builds,
change `build-win64`'s `depends_on` to `[build-linux64]`.

`skip_clone` is set: both checkouts under `/src` are managed by the build
server, and the Firefox tree alone is over 6 GB.

Two kinds of state cross step boundaries, and neither can live in `/tmp`,
because every step is its own container:

| | |
| --- | --- |
| `/state/ci` | version and tag being built, and each target's objdir |
| `/state/artifacts` | the built MARs and installers |

A poll that finds nothing new records a skip flag, and the later steps return
immediately, so a quiet cycle appears as a short green run rather than a
failure — Woodpecker has no equivalent of halting a pipeline mid-run.

## Day-to-day

```sh
# What is it doing?
curl https://firefox-builds.sai.town/status.json
sudo docker logs --tail 50 firefox-fork-builder

# Force a rebuild of the current release
rm /mnt/tank/firefox-fork/state/last-built
sudo docker restart firefox-fork-builder
```

### Running one step by hand

`make_mar.sh` takes the object directory as an argument, so packaging and
signing can be re-run on an existing build without going through a whole cycle.
Two variables the loop normally supplies have to be set explicitly: without
`FORK_NSS_DIR` config.sh falls back to `$HOME/.ssm9-mar-nss`, and `FORK_SIGNMAR`
selects a host-native signmar.

```sh
OBJ=/src/firefox/obj-x86_64-pc-linux-gnu

sudo docker exec -it firefox-fork-builder bash -c "
  set -x
  export FORK_NSS_DIR=/state/mar-nss
  export FORK_SIGNMAR=$OBJ/dist/bin/signmar
  git config --global --add safe.directory /src/firefox
  rm -rf /tmp/martest && mkdir -p /tmp/martest
  /src/firefox/tools/fork/make_mar.sh linux64 $OBJ /tmp/martest
"
```

`set -x` traces every command, so the failing one is visible directly rather
than inferred from an exit status.

The pieces it depends on, checkable individually:

```sh
# the two tools, in the two different places they are built
sudo docker exec firefox-fork-builder ls -l \
  /src/firefox/obj-x86_64-pc-linux-gnu/dist/host/bin/mar \
  /src/firefox/obj-x86_64-pc-linux-gnu/dist/bin/signmar

# signmar runs here, and its usage text
sudo docker exec firefox-fork-builder \
  /src/firefox/obj-x86_64-pc-linux-gnu/dist/bin/signmar 2>&1 | head -20

# the signing key and certificates
sudo docker exec firefox-fork-builder ls -l /state/mar-nss
sudo docker exec firefox-fork-builder certutil -L -d /state/mar-nss
```

The loop only polls every six hours, so it will be asleep and will not interfere.

### Watching a build

Firefox is roughly 35k compilation units, so sccache's request count is the
best progress signal. Call it by full path: the build uses the sccache that
`mach bootstrap` installed, while a bare `sccache` on PATH is the one from the
image. They are different versions, and the mismatched client cannot talk to
the running server -- it fails with "Mismatch of client/server versions?".

```sh
sudo docker exec firefox-fork-builder \
  /state/mozbuild/sccache/sccache --show-stats
```

Hit rate is near zero on a first build and high afterwards, which is what makes
later releases and clobbers cheap.

A backend-independent alternative, if sccache is unavailable:

```sh
sudo find /mnt/tank/firefox-fork/src/firefox/obj-x86_64-pc-linux-gnu \
  -name '*.o' | wc -l
```

The object directory lives under `src/` rather than the `obj/` dataset, because
mozbuild ignores the MOZ_OBJDIR environment variable when a mozconfig is in use
(python/mozbuild/mozbuild/mozconfig.py:121). The loop asks mach where it built
rather than assuming, so this is cosmetic -- but `obj/` sits unused, and `src/`
grows by tens of gigabytes.

## Updating the pipeline scripts

Everything except `build-loop.sh` is read from `/src` at run time, so updating
the checkout is enough:

```sh
cd /mnt/tank/firefox-fork/src/firefox
sudo git fetch origin && sudo git checkout -f -B fork-build origin/ssm9/fork-build
sudo docker restart firefox-fork-builder
```

`build-loop.sh` is the exception: it is baked into the image, because it has to
exist before there is a checkout to run it from. It hands over to the in-tree
copy when the two differ, so in normal operation updating `/src` still suffices
— but that only works once the image contains a version that knows how to hand
over. Rebuild it from `/src`, which is already the verified-correct source:

```sh
cd /mnt/tank/firefox-fork/src/firefox/tools/fork/docker
sudo docker build -t firefox-fork-builder:latest .

# The container MUST be recreated, not restarted. `docker restart` stops and
# starts the same container, and a container is bound to the image it was
# created from -- so a restart silently keeps running the old image.
sudo docker rm -f firefox-fork-builder
```

Then start the app from the TrueNAS UI, which recreates the container from the
rebuilt image.

Look for `In-tree build loop differs from the image copy; handing over to it` to
confirm the handover is working.

To check which copy is running:

```sh
sudo docker exec firefox-fork-builder grep -c FORK_LOOP_REEXEC /usr/local/bin/build-loop.sh
```

`0` means the image predates the handover and is ignoring `/src` entirely.

Alternatively, skip the image copy for good by pointing the container straight
at the checkout, which works because `/src` persists across restarts:

```yaml
    entrypoint: ["/bin/bash", "/src/firefox/tools/fork/docker/build-loop.sh"]
```

Only do this on an already-deployed instance — on a fresh one `/src` is empty
and there is nothing to execute.
