#!/usr/bin/env bash
#
# Build the ISO and check it.
#
#   1/3  checks that need no ISO
#   2/3  ./build.sh
#   3/3  checks that need the ISO
#
# The checks run in the Docker verification image, so the host needs Docker
# and nothing else. Phase 3 checks only the image; it does not repeat phase 1.

set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
RUNNER="$ROOT/test/run-docker.sh"

msg() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

(($# == 0)) || die "no arguments; run build.sh directly for build options"

[[ -r $RUNNER ]] || die "missing test runner: $RUNNER"
[[ -x $ROOT/build.sh ]] || die "build.sh is not executable"

msg "1/3 checks that need no ISO"
bash "$RUNNER" --static || die "the checks that need no ISO failed"

msg "2/3 building the ISO"
"$ROOT/build.sh" || die "the ISO build failed"

iso=$(find "$ROOT/out" -type f -name '*.iso' -printf '%T@ %p\n' \
    | sort -n | tail -n 1 | cut -d' ' -f2-)
[[ -n $iso ]] || die "the build produced no ISO"
printf '    %s\n' "$iso"

msg "3/3 checks that need the ISO"
bash "$RUNNER" "$iso" || die "the checks that need the ISO failed"

msg "done"
printf '    ISO: %s\n' "$iso"
