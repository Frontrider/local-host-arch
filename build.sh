#!/usr/bin/env bash
#
# Build the local-host-arch Manjaro live ISO with manjaro-tools' buildiso.
#
# buildiso needs root for its chroots. This script re-executes itself through
# sudo, but keeps every artefact and every manjaro-tools config file inside
# this directory (work/), so nothing is written to ~/.config or /var/lib.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"

PROFILES_DIR="$SCRIPT_DIR/iso-profiles"
OUT_DIR="$SCRIPT_DIR/out"
WORK_DIR="$SCRIPT_DIR/work"

# Defaults (override on the command line or through the environment).
PROFILE="${PROFILE:-local-host}"
EDITION="${EDITION:-manjaro}"
KERNEL="${KERNEL:-linux618}"
BRANCH="${BRANCH:-stable}"
COMPRESSION="${COMPRESSION:-zstd}"
BUILD_MIRROR="${BUILD_MIRROR:-https://mirrors.manjaro.org/repo}"
BUILD_RETRIES="${BUILD_RETRIES:-3}"

DO_CLEAN=false
DO_CHECK=false
NO_CHECK=false
IMAGES_ONLY=false
ISO_ONLY=false
INCREMENTAL=false

PROFILE_DIR="$PROFILES_DIR/$EDITION/$PROFILE"
CONF_HOME="$WORK_DIR/home"
CONF_DIR="$CONF_HOME/.config/manjaro-tools"

msg()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

Builds the Manjaro live ISO for the '$EDITION/$PROFILE' profile.

Options:
  -p, --profile NAME       profile directory (default: $PROFILE)
  -e, --edition NAME       edition directory (default: $EDITION)
  -k, --kernel NAME        kernel package (default: $KERNEL)
  -b, --branch NAME        mirror branch: stable, testing, unstable (default: $BRANCH)
  -d, --compression ALGO   squashfs compression: zstd, xz, gzip, lz4, lzo (default: $COMPRESSION)
  -M, --mirror URL         Manjaro mirror root (default: $BUILD_MIRROR)
      --retries N          retry the build N times on download failures (default: $BUILD_RETRIES)
  -c, --incremental        keep the existing chroots and reuse build markers
      --resume             same as --incremental; use after a failed build
  -x, --images-only        only build squashfs images (no ISO)
  -z, --iso-only           only repack an ISO from previously built images (implies -c)
      --check              only verify host tools and profile packages, then exit
      --no-check           do not verify profile packages before building
      --clean              remove out/ and work/, then exit
  -h, --help               show this help

Environment:
  PROFILE, EDITION, KERNEL, BRANCH, COMPRESSION, BUILD_MIRROR, BUILD_RETRIES
                         same as the options above

Output:
  $OUT_DIR/$EDITION/$PROFILE/<release>/...
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            -p|--profile)       PROFILE="${2:?missing value for $1}"; shift 2 ;;
            -e|--edition)       EDITION="${2:?missing value for $1}"; shift 2 ;;
            -k|--kernel)        KERNEL="${2:?missing value for $1}"; shift 2 ;;
            -b|--branch)        BRANCH="${2:?missing value for $1}"; shift 2 ;;
            -d|--compression)   COMPRESSION="${2:?missing value for $1}"; shift 2 ;;
            -M|--mirror)        BUILD_MIRROR="${2:?missing value for $1}"; shift 2 ;;
            --retries)          BUILD_RETRIES="${2:?missing value for $1}"; shift 2 ;;
            -c|--incremental|--resume) INCREMENTAL=true; shift ;;
            -x|--images-only)   IMAGES_ONLY=true; shift ;;
            -z|--iso-only)      ISO_ONLY=true; INCREMENTAL=true; shift ;;
            --check)            DO_CHECK=true; shift ;;
            --no-check)         NO_CHECK=true; shift ;;
            --clean)            DO_CLEAN=true; shift ;;
            -h|--help)          usage; exit 0 ;;
            --)                 shift; break ;;
            *)                  usage >&2; die "unknown argument: $1" ;;
        esac
    done

    PROFILE_DIR="$PROFILES_DIR/$EDITION/$PROFILE"
    CONF_DIR="$CONF_HOME/.config/manjaro-tools"

    [[ -n $PROFILE && -n $EDITION ]] || die "profile and edition must not be empty"
    [[ $BUILD_MIRROR == http://* || $BUILD_MIRROR == https://* ]] \
        || die "mirror must be an http(s) URL: $BUILD_MIRROR"
    [[ $BUILD_RETRIES =~ ^[0-9]+$ ]] || die "retries must be a number: $BUILD_RETRIES"
    if $IMAGES_ONLY && $ISO_ONLY; then
        die "--images-only and --iso-only cannot be combined"
    fi
}

# Print the package names in a profile package list, after applying the same
# transformations buildiso does (comments, KERNEL, >flag tokens).
profile_packages() {
    local list=$1
    sed -e '/^[[:space:]]*>blacklist/d' -e 's/#.*//' "$list" \
        | sed -e "s/KERNEL/$KERNEL/g" \
        | tr ' ' '\n' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | grep -v '^>'
}

declare -A CMD_PACKAGE=(
    [buildiso]=manjaro-tools-iso-git
    [xorriso]=libisoburn
    [mktorrent]=mktorrent
    [kwalify]=ruby-kwalify
    [mkfs.fat]=dosfstools
    [mksquashfs]=squashfs-tools
    [grub-mkstandalone]=grub
    [pacman]=pacman
    [rsync]=rsync
    [openssl]=openssl
    [git]=git
    [qemu-system-x86_64]=qemu-base
    [qemu-img]=qemu-base
)

run_checks() {
    local rc=0 missing=() pkg code

    msg "Build requirements"

    for pkg in buildiso xorriso mktorrent kwalify mkfs.fat mksquashfs \
               grub-mkstandalone grub-mkimage grub-editenv pacman rsync \
               openssl perl git; do
        if command -v "$pkg" >/dev/null 2>&1; then
            info "ok       $pkg"
        else
            info "MISSING  $pkg  (package: ${CMD_PACKAGE[$pkg]:-unknown})"
            rc=1
        fi
    done

    for pkg in /usr/lib/manjaro-tools/util-yaml.sh \
               /usr/lib/manjaro-tools/util-iso.sh \
               /usr/share/manjaro-tools/pacman-default.conf; do
        if [[ -r $pkg ]]; then
            info "ok       $pkg"
        else
            info "MISSING  $pkg  (packages: manjaro-tools-base-git/manjaro-tools-iso-git/manjaro-tools-yaml-git)"
            rc=1
        fi
    done

    msg "Profile"
    if [[ -d $PROFILE_DIR ]]; then
        info "ok       $PROFILE_DIR"
    else
        info "MISSING  $PROFILE_DIR"
        rc=1
    fi
    if [[ -r $PROFILES_DIR/repo_info ]]; then
        info "ok       $PROFILES_DIR/repo_info"
    else
        info "MISSING  $PROFILES_DIR/repo_info"
        rc=1
    fi
    for pkg in Packages-Root Packages-Live Packages-Desktop; do
        if [[ -r $PROFILE_DIR/$pkg ]]; then
            info "ok       $PROFILE_DIR/$pkg"
        else
            info "MISSING  $PROFILE_DIR/$pkg"
            rc=1
        fi
    done

    msg "Packages for $EDITION/$PROFILE (kernel: $KERNEL)"
    if command -v pacman >/dev/null 2>&1; then
        if pacman -Si "$KERNEL" >/dev/null 2>&1; then
            info "ok       $KERNEL"
        else
            info "MISSING  $KERNEL (not found in the configured repos)"
            rc=1
        fi
        if [[ -r $PROFILE_DIR/Packages-Root ]]; then
            local -a lists=("$PROFILE_DIR/Packages-Root" "$PROFILE_DIR/Packages-Live")
            [[ -r $PROFILE_DIR/Packages-Desktop ]] && lists+=("$PROFILE_DIR/Packages-Desktop")
            missing=()
            while read -r pkg; do
                [[ -z $pkg ]] && continue
                pacman -Sp --print-format '%n' "$pkg" >/dev/null 2>&1 \
                    || missing+=("$pkg")
            done < <(for l in "${lists[@]}"; do profile_packages "$l"; done)
            if ((${#missing[@]})); then
                info "MISSING  ${missing[*]}"
                rc=1
            else
                info "ok       every package name resolves in the repo databases"
            fi
        fi
    else
        info "MISSING  pacman (cannot verify profile packages)"
        rc=1
    fi

    msg "Build mirror"
    info "$BUILD_MIRROR (branch: $BRANCH)"
    if command -v curl >/dev/null 2>&1; then
        code=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 10 \
               "$BUILD_MIRROR/$BRANCH/core/x86_64/core.db" 2>/dev/null || true)
        if [[ $code == 200 || $code == 206 ]]; then
            info "ok       core.db reachable"
        else
            info "WARN     core.db returned ${code:-no response}; use --mirror to select another mirror"
        fi
    else
        info "WARN     curl not installed; skipping mirror reachability check"
    fi

    msg "Virtual machine"
    for pkg in qemu-system-x86_64 qemu-img; do
        if command -v "$pkg" >/dev/null 2>&1; then
            info "ok       $pkg"
        else
            info "MISSING  $pkg  (package: qemu-base)"
            rc=1
        fi
    done
    if [[ -r /usr/share/edk2/x64/OVMF_CODE.4m.fd && -r /usr/share/edk2/x64/OVMF_VARS.4m.fd ]]; then
        info "ok       OVMF firmware (edk2-ovmf)"
    else
        info "MISSING  /usr/share/edk2/x64/OVMF_{CODE,VARS}.4m.fd  (package: edk2-ovmf)"
        rc=1
    fi
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        info "ok       /dev/kvm (hardware acceleration)"
    else
        info "WARN     /dev/kvm not accessible; run-vm.sh will fall back to TCG (slow)"
    fi
    for pkg in qemu-system-x86_64; do
        if command -v "$pkg" >/dev/null 2>&1; then
            if "$pkg" -display help 2>&1 | grep -qwE 'gtk|sdl'; then
                info "ok       native QEMU display backend (optional, not required)"
            else
                info "info     no gtk/sdl backend; run-vm.sh uses VNC (qemu-desktop is optional)"
            fi
        fi
    done

    return "$rc"
}

prepare_dirs() {
    mkdir -p "$OUT_DIR" "$WORK_DIR/chroots" "$WORK_DIR/logs" "$WORK_DIR/tmp" \
             "$WORK_DIR/vm" "$CONF_DIR"

    # manjaro-tools configuration for this project only. buildiso gets
    # HOME=$CONF_HOME and no SUDO_USER, so it reads these files instead of
    # ~/.config/manjaro-tools.
    printf 'run_dir="%s"\n' "$PROFILES_DIR" > "$CONF_DIR/iso-profiles.conf"
    cat > "$CONF_DIR/manjaro-tools.conf" <<EOF
# Generated by build.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Do not edit.
log_dir="$WORK_DIR/logs"
tmp_dir="$WORK_DIR/tmp"
build_mirror="$BUILD_MIRROR"
target_branch="$BRANCH"
target_arch="x86_64"
EOF

    chown -R "$RUN_UID:$RUN_GID" "$CONF_HOME" "$WORK_DIR/logs" "$WORK_DIR/vm" "$OUT_DIR" 2>/dev/null || true
}

# --- stale build detection ------------------------------------------------
# buildiso marks completed image steps with build.make_image_* files and
# skips them on -c. If the profile, overlays or build parameters change
# after that, the marking would keep a stale image. The helpers below
# invalidate exactly the affected images so --resume really reflects the
# current profile.

sources_newer_than() {
    local marker=$1
    local p
    shift
    [[ -e $marker ]] || return 1
    for p in "$@"; do
        [[ -e $p ]] || continue
        if [[ -d $p ]]; then
            [[ $p -nt $marker ]] && return 0
            [[ -n $(find "$p" -type f -newer "$marker" -print -quit 2>/dev/null) ]] && return 0
        else
            [[ $p -nt $marker ]] && return 0
        fi
    done
    return 1
}

invalidate_image() {
    local name=$1 step=$2
    local arch_dir="$WORK_DIR/chroots/$PROFILE/x86_64"
    local dir="$arch_dir/$name" marker="$arch_dir/build.$step"
    if mountpoint -q "$dir" 2>/dev/null; then
        umount -l "$dir" 2>/dev/null || true
    fi
    if [[ -e $dir || -e $marker ]]; then
        rm -rf --one-file-system -- "$dir" "$marker"
        info "stale $name image invalidated"
    fi
}

refresh_stale_build_state() {
    local arch_dir="$WORK_DIR/chroots/$PROFILE/x86_64"
    local state="$WORK_DIR/.build-state"
    local root=false desktop=false live=false rebuild_boot=false
    local kernel_changed=false branch_changed=false compression_changed=false

    [[ -d $arch_dir ]] || return 0

    if [[ -r $state ]]; then
        # shellcheck disable=SC1090
        source "$state"
        [[ -n ${build_state_kernel:-} && ${build_state_kernel} != "$KERNEL" ]] && kernel_changed=true
        [[ -n ${build_state_branch:-} && ${build_state_branch} != "$BRANCH" ]] && branch_changed=true
        [[ -n ${build_state_compression:-} && ${build_state_compression} != "$COMPRESSION" ]] && compression_changed=true
    fi

    if $kernel_changed || $branch_changed; then
        root=true
    fi

    if sources_newer_than "$arch_dir/build.make_image_root" \
        "$PROFILE_DIR/Packages-Root" "$PROFILE_DIR/root-overlay"; then
        root=true
    fi
    if $root; then
        invalidate_image rootfs make_image_root
        desktop=true
        rebuild_boot=true
    fi

    if sources_newer_than "$arch_dir/build.make_image_desktop" \
        "$PROFILE_DIR/Packages-Desktop" "$PROFILE_DIR/desktop-overlay"; then
        desktop=true
    fi
    if $desktop; then
        invalidate_image desktopfs make_image_desktop
        live=true
        rebuild_boot=true
    fi

    if sources_newer_than "$arch_dir/build.make_image_live" \
        "$PROFILE_DIR/Packages-Live" "$PROFILE_DIR/live-overlay" \
        "$PROFILE_DIR/profile.conf" "$PROFILE_DIR/Packages-Desktop" \
        "$PROFILE_DIR/desktop-overlay"; then
        live=true
    fi
    if $live; then
        invalidate_image livefs make_image_live
        rebuild_boot=true
    fi

    if $compression_changed; then
        rm -rf --one-file-system -- "$WORK_DIR/chroots/$PROFILE/iso"
        rebuild_boot=true
    fi

    if $rebuild_boot; then
        rm -f -- "$arch_dir/build.make_image_boot" "$arch_dir/build.make_grub"
    fi
}

write_build_state() {
    printf 'build_state_kernel=%q\nbuild_state_branch=%q\nbuild_state_compression=%q\n' \
        "$KERNEL" "$BRANCH" "$COMPRESSION" > "$WORK_DIR/.build-state"
    chown "$RUN_UID:$RUN_GID" "$WORK_DIR/.build-state" 2>/dev/null || true
}

run_build() {
    local -a base=(
        buildiso
        -p "$PROFILE"
        -a x86_64
        -b "$BRANCH"
        -k "$KERNEL"
        -d "$COMPRESSION"
        -t "$OUT_DIR"
        -r "$WORK_DIR/chroots"
    )
    local attempt=1 rc=0 log
    log="$WORK_DIR/logs/iso-build-$(date +%Y%m%d-%H%M%S).log"

    if $IMAGES_ONLY; then base+=(-x); fi
    if $ISO_ONLY; then base+=(-z); fi

    while :; do
        local -a args=("${base[@]}")
        local attempt_log="$log.attempt-$attempt"
        if $INCREMENTAL || ((attempt > 1)); then args+=(-c); fi

        msg "Running buildiso (attempt $attempt/$BUILD_RETRIES)"
        info "${args[*]}"
        info "log: $log"

        set +e
        env -u SUDO_USER -u SUDO_UID -u SUDO_GID \
            USER="$RUN_USER" LOGNAME="$RUN_USER" HOME="$CONF_HOME" \
            "${args[@]}" 2>&1 | tee "$attempt_log"
        rc=${PIPESTATUS[0]}
        set -e

        cat "$attempt_log" >> "$log"
        chown "$RUN_UID:$RUN_GID" "$log" 2>/dev/null || true

        ((rc == 0)) && { rm -f "$attempt_log"; return 0; }

        if ((attempt >= BUILD_RETRIES)); then
            warn "buildiso failed (exit $rc) after $attempt attempt(s); log: $log"
            info "Retry later with: $SCRIPT_PATH --resume"
            return "$rc"
        fi

        if grep -qiE 'failed retrieving file|failed to retrieve|download library error|connection timed out|could not resolve|operation too slow|failed to download' "$attempt_log"; then
            rm -f "$attempt_log"
            attempt=$((attempt + 1))
            INCREMENTAL=true
            warn "download failure; resuming incrementally in $((attempt * 5))s (attempt $attempt/$BUILD_RETRIES)"
            sleep $((attempt * 5))
        else
            rm -f "$attempt_log"
            warn "buildiso failed (exit $rc); log: $log"
            info "After fixing the cause, resume with: $SCRIPT_PATH --resume"
            return "$rc"
        fi
    done
}

latest_iso() {
    find "$OUT_DIR" -type f -name '*.iso' -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -n 1 | cut -d' ' -f2-
}

main() {
    parse_args "$@"

    if $DO_CHECK; then
        run_checks
        exit $?
    fi

    # buildiso itself insists on root. Elevate once, early, and keep the
    # invoking user so the resulting files are not owned by root.
    if ((EUID != 0)); then
        command -v sudo >/dev/null 2>&1 || die "buildiso needs root; install sudo or run this script as root"
        exec sudo env \
            PROJECT_USER="$(id -un)" \
            PROJECT_UID="$(id -u)" \
            PROJECT_GID="$(id -g)" \
            "$SCRIPT_PATH" "$@"
    fi

    RUN_USER="${PROJECT_USER:-${SUDO_USER:-root}}"
    id -u "$RUN_USER" >/dev/null 2>&1 || die "unknown user: $RUN_USER"
    RUN_UID=$(id -u "$RUN_USER")
    RUN_GID=$(id -g "$RUN_USER")

    if $DO_CLEAN; then
        msg "Removing $OUT_DIR and $WORK_DIR"
        rm -rf -- "$OUT_DIR" "$WORK_DIR"
        exit 0
    fi

    if ! $NO_CHECK; then
        run_checks || die "requirements are not satisfied (see above); use --check for details"
    fi

    prepare_dirs
    if $INCREMENTAL && ! $ISO_ONLY; then
        refresh_stale_build_state
    fi
    write_build_state
    run_build

    if $IMAGES_ONLY; then
        msg "Squashfs images built"
        info "Continue with: $SCRIPT_PATH --iso-only"
        exit 0
    fi

    local iso
    iso=$(latest_iso)
    [[ -n $iso ]] || die "buildiso finished but no ISO was found under $OUT_DIR"

    printf '\n'
    msg "ISO ready"
    info "$iso"
    info "size: $(du -h -- "$iso" | cut -f1)"
    printf '\n'
    info "Boot it with: $SCRIPT_DIR/run-vm.sh"
}

main "$@"
