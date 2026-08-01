#!/usr/bin/env python3
"""Generate static update.xml manifests from the per-target MAR metadata.

Writes one manifest per BUILD_TARGET string under <outdir>/<build_target>/<channel>/,
matching the URL template baked into build/application.ini.in.

The manifest always advertises the newest build. Firefox compares the
advertised buildID/appVersion against its own and ignores anything not newer,
so there is no need for the server to know what the client is running -- which
is what makes static hosting sufficient.
"""

import argparse
import json
import pathlib
import sys
from xml.sax.saxutils import quoteattr

# Mirrors fork_build_targets() in config.sh. On Windows the ABI carries the
# *running* CPU architecture (toolkit/modules/UpdateUtils.sys.mjs:1062), so one
# build answers to more than one path.
BUILD_TARGETS = {
    "linux64": ["Linux_x86_64-gcc3"],
    "win64": ["WINNT_x86_64-msvc-x64", "WINNT_x86_64-msvc-aarch64"],
    "macos-aarch64": ["Darwin_aarch64-gcc3"],
}


def manifest_for(meta, release_base_url):
    url = f"{release_base_url}/{meta['file']}"
    attrs = {
        "type": "minor",
        "displayVersion": meta["version"],
        "appVersion": meta["version"],
        "platformVersion": meta["version"],
        "buildID": meta["buildID"],
    }
    patch = {
        "type": "complete",
        "URL": url,
        "hashFunction": meta["hashFunction"],
        "hashValue": meta["hashValue"],
        "size": str(meta["size"]),
    }
    a = " ".join(f"{k}={quoteattr(v)}" for k, v in attrs.items())
    p = " ".join(f"{k}={quoteattr(v)}" for k, v in patch.items())
    return f'<?xml version="1.0" encoding="UTF-8"?>\n<updates>\n  <update {a}>\n    <patch {p}/>\n  </update>\n</updates>\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--metadata",
        nargs="+",
        required=True,
        help="per-target *.mar.json files written by make_mar.sh",
    )
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument(
        "--release-base-url",
        required=True,
        help="base URL the MAR files are downloadable from",
    )
    args = ap.parse_args()

    outdir = pathlib.Path(args.outdir)
    written = []

    for path in args.metadata:
        meta = json.loads(pathlib.Path(path).read_text())
        target = meta["target"]
        if target not in BUILD_TARGETS:
            print(f"ERROR: no BUILD_TARGET mapping for {target!r}", file=sys.stderr)
            return 1

        xml = manifest_for(meta, args.release_base_url)
        for build_target in BUILD_TARGETS[target]:
            dest = outdir / build_target / args.channel / "update.xml"
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(xml)
            written.append(dest)

    for dest in written:
        print(f"wrote {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
