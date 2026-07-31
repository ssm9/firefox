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

## 4. Seed the rebase base

This tells the loop which commits are the fork's own. The branch was developed
on mozilla-central, so the initial value is a **commit, not a release tag**:

```sh
echo 4eb5d723d627edec42ca3e5d606e1227c656dfca \
  > /mnt/tank/firefox-fork/state/fork-base
```

The loop overwrites this with a release tag after its first successful rebase.

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

**Expect the rebase to need attention.** The patch series was written against
mozilla-central (154.0a1) and the server targets mozilla-release, an older
divergent branch. Replaying 24 commits across that gap is exactly what the
conflict guard is for. If it stops:

1. Resolve the conflicts on `ssm9/fork-build` and push
2. Set `state/fork-base` to the release tag it was rebasing onto
3. Re-run

When it succeeds, start the app again for the normal polling loop.

## 10. Verify before trusting it

Patch present in the build — this file does not exist in stock Firefox:

```sh
unzip -l /mnt/tank/firefox-fork/obj/obj-fork-linux64/dist/firefox/omni.ja \
  chrome/toolkit/content/extensions/child/ext-downloads.js
```

MAR signature against the certificate compiled into the updater:

```sh
sudo docker exec -it firefox-fork-builder \
  /obj/obj-fork-linux64/dist/host/bin/signmar \
  -D /src/firefox/toolkit/mozapps/update/updater/release_primary.der \
  -v /www/downloads/<version>/firefox-<version>.linux64.complete.mar
```

Manifest at the exact path a client asks for:

```sh
curl https://firefox-builds.sai.town/updates/Linux_x86_64-gcc3/ssm9/update.xml
```

**The test that actually matters:** install the published build, wait for the
next release to be built, let it auto-update, and confirm the extension still
routes downloads afterwards. Everything else can pass while this fails, and
this is the entire reason the pipeline exists.

## Day-to-day

```sh
# What is it doing?
curl https://firefox-builds.sai.town/status.json
sudo docker logs --tail 50 firefox-fork-builder

# Force a rebuild of the current release
rm /mnt/tank/firefox-fork/state/last-built
sudo docker restart firefox-fork-builder
```

To pick up changes to the pipeline scripts, pull in `fork-config`, rebuild the
image, and recreate the app. The builder's own `/src` clone updates itself on
every cycle.
