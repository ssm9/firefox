#!/usr/bin/env python3
"""Find the newest upstream Firefox release tag, and whether we have built it.

Release tags on the mozilla-firefox/firefox mirror look like:

    FIREFOX_153_0_RELEASE      -> 153.0
    FIREFOX_153_0_1_RELEASE    -> 153.0.1   (dot release; these are the
                                             security updates)

Deliberately excluded: beta (FIREFOX_153_0b1_RELEASE), ESR
(FIREFOX_ESR_140_10_X_RELBRANCH), and relbranches.

Emits GITHUB_OUTPUT-style key=value lines so the workflow can gate on it.
"""

import argparse
import os
import re
import subprocess
import sys

TAG_RE = re.compile(r"^FIREFOX_(\d+)_(\d+)(?:_(\d+))?_RELEASE$")


def parse_tags(lines):
    found = {}
    for line in lines:
        if "\t" not in line:
            continue
        ref = line.split("\t", 1)[1].strip()
        if not ref.startswith("refs/tags/"):
            continue
        tag = ref[len("refs/tags/") :]
        # Annotated tags appear twice, once with a ^{} suffix.
        if tag.endswith("^{}"):
            tag = tag[:-3]
        m = TAG_RE.match(tag)
        if m:
            major, minor, patch = m.groups()
            key = (int(major), int(minor), int(patch or 0))
            found[key] = tag
    return found


def version_str(key):
    major, minor, patch = key
    return f"{major}.{minor}" if patch == 0 else f"{major}.{minor}.{patch}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--remote", default="https://github.com/mozilla-firefox/firefox")
    ap.add_argument(
        "--last-built", default="", help="version string of the last build we published"
    )
    args = ap.parse_args()

    try:
        out = subprocess.run(
            ["git", "ls-remote", "--tags", args.remote, "FIREFOX_*_RELEASE"],
            capture_output=True,
            text=True,
            check=True,
            timeout=120,
        ).stdout.splitlines()
    except subprocess.CalledProcessError as e:
        print(f"ERROR: git ls-remote failed: {e.stderr}", file=sys.stderr)
        return 1
    except subprocess.TimeoutExpired:
        print("ERROR: git ls-remote timed out", file=sys.stderr)
        return 1

    tags = parse_tags(out)
    if not tags:
        print("ERROR: no release tags matched", file=sys.stderr)
        return 1

    newest = max(tags)
    version = version_str(newest)
    tag = tags[newest]
    should_build = "true" if version != args.last_built.strip() else "false"

    result = {"version": version, "tag": tag, "should_build": should_build}

    for k, v in result.items():
        print(f"{k}={v}")

    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            for k, v in result.items():
                fh.write(f"{k}={v}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
