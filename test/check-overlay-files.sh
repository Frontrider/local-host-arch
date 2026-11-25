#!/usr/bin/env bash
# Check that every file from the profile overlays made it into the built
# images, byte for byte.
#
#     check-overlay-files.sh <dir with *fs.sfs> [profile dir]
#
# The directory must contain the squashfs images the profile writes to:
# rootfs.sfs, desktopfs.sfs and livefs.sfs. Only the images that have a
# matching *-overlay in the profile are checked.
#
# build.sh runs this right after buildiso; test/verify-iso.test.sh runs the
# same script against the squashfs files taken from the ISO.
#
# buildiso copies overlays with `cp -LR`, so a symlink in the profile becomes
# the thing it points at in the image. The comparison follows symlinks the
# same way: it walks the overlay with `find -L` and compares regular files.
#
# Problems are printed one per line. The exit status is non-zero when a file
# is missing or the content changed.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)

SFS_DIR="${1:-}"
PROFILE="${2:-${LOCAL_HOST_PROFILE:-$REPO_ROOT/iso-profiles/manjaro/local-host}}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -n $SFS_DIR ]] || die "usage: ${0##*/} <dir-with-sfs-images> [profile dir]"
[[ -d $SFS_DIR ]] || die "not a directory: $SFS_DIR"
[[ -d $PROFILE ]] || die "profile not found: $PROFILE"
command -v unsquashfs >/dev/null 2>&1 || die "unsquashfs is required"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/local-host-overlay.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

status=0
checked=0

for name in root desktop live; do
    overlay="$PROFILE/$name-overlay"
    [[ -d $overlay ]] || continue

    sfs="$SFS_DIR/${name}fs.sfs"
    if [[ ! -f $sfs ]]; then
        printf 'missing: %s\n' "$sfs"
        status=1
        continue
    fi

    # -L follows the profile's symlinks, exactly like buildiso's cp -LR.
    paths=()
    while IFS= read -r path; do
        paths+=("$path")
    done < <(find -L "$overlay" -mindepth 1 -type f -printf '%P\n' 2>/dev/null)
    ((${#paths[@]})) || continue

    target="$tmp/$name"
    # -no-exit-code keeps one missing path from aborting the extraction, so
    # every difference is reported below. -no-wildcards makes the paths match
    # literally.
    if ! output=$(unsquashfs -q -no-xattrs -no-exit-code -no-wildcards \
            -d "$target" "$sfs" "${paths[@]}" 2>&1); then
        printf '%s\n' "$output" >&2
        die "unsquashfs could not read $sfs"
    fi

    for path in "${paths[@]}"; do
        target_path="$target/$path"
        if [[ ! -f $target_path ]]; then
            printf 'missing: %s/%s\n' "$name" "$path"
            status=1
        elif ! cmp -s -- "$overlay/$path" "$target_path"; then
            printf 'differs: %s/%s\n' "$name" "$path"
            status=1
        fi
        checked=$((checked + 1))
    done
done

((checked > 0)) || die "no overlay files found in $PROFILE"

printf 'overlay files: %d checked\n' "$checked"
exit "$status"
