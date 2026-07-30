#!/bin/bash
# One-time generation of the MAR signing key for this fork.
#
# The resulting public certificate is committed into the tree and compiled into
# the updater; the private key stays in the NSS database and is used to sign
# every MAR the pipeline produces.
#
# LOSING THE PRIVATE KEY STRANDS EVERY INSTALLED CLIENT. There is no recovery
# path: an installed build will only accept MARs signed by the key compiled
# into it, so a lost key means every user must manually reinstall. Back up
# $FORK_NSS_DIR somewhere durable and offline before publishing any build.

set -euo pipefail

cd "$(dirname "$0")"
. ./config.sh
cd "$(git rev-parse --show-toplevel)"

if [ -d "$FORK_NSS_DIR" ]; then
  echo "ERROR: $FORK_NSS_DIR already exists." >&2
  echo "Refusing to overwrite an existing signing key. Remove it deliberately" >&2
  echo "if you really intend to generate a new one -- doing so will strand" >&2
  echo "every already-published build." >&2
  exit 1
fi

VALIDITY_MONTHS="${VALIDITY_MONTHS:-120}"

mkdir -p "$FORK_NSS_DIR"
chmod 700 "$FORK_NSS_DIR"

# Empty password: the database is protected by filesystem permissions and, in
# CI, by being reconstructed from a secret on each run.
PWFILE="$(mktemp)"
trap 'rm -f "$PWFILE" noise.bin' EXIT
: > "$PWFILE"

certutil -N -d "$FORK_NSS_DIR" -f "$PWFILE"

# certutil wants entropy from a file for key generation.
dd if=/dev/urandom of=noise.bin bs=32 count=1 status=none

certutil -S \
  -d "$FORK_NSS_DIR" \
  -f "$PWFILE" \
  -z noise.bin \
  -n "$FORK_MAR_CERT_NICKNAME" \
  -s "CN=$FORK_MAR_CERT_NICKNAME,O=ssm9 firefox fork" \
  -x \
  -t ",," \
  -m "$(od -An -N4 -tu4 < /dev/urandom | tr -d ' ')" \
  -v "$VALIDITY_MONTHS" \
  -k rsa -g 4096 \
  -Z SHA384 \
  -1 -2 -5 --keyUsage digitalSignature,nonRepudiation

# The certificate is written next to the key rather than into the source tree.
# The build loop copies it over toolkit/mozapps/update/updater/release_*.der
# before each build, which keeps the branch free of per-deployment material:
# nothing to commit, nothing to conflict on during a rebase, and no ordering
# problem where the builder must clone a branch that already contains the
# certificate for a key that does not exist yet.
certutil -L -d "$FORK_NSS_DIR" -n "$FORK_MAR_CERT_NICKNAME" -r \
  > "$FORK_NSS_DIR/release_primary.der"

# The updater accepts two certificates so a key can be rotated without
# stranding clients: publish a build trusting both, then start signing with the
# new one. Until there is a second key, both slots hold the same certificate.
cp "$FORK_NSS_DIR/release_primary.der" "$FORK_NSS_DIR/release_secondary.der"

echo
echo "Signing key and certificate created in $FORK_NSS_DIR"
echo
echo "Next steps:"
echo "  1. Back up $FORK_NSS_DIR offline. There is no recovery if it is lost:"
echo "     an installed build only accepts MARs signed by the key compiled"
echo "     into it, so losing this means every user reinstalls by hand."
echo "  2. Make sure it is the build server's state volume at"
echo "     <dataset>/state/mar-nss -- the build loop reads both the key and"
echo "     the certificate from there."
