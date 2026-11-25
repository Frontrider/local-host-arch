#!/usr/bin/env bash
#
# Build the local-host-arch Manjaro live ISO with manjaro-tools' buildiso.
#
# buildiso needs root for its chroots. This script re-executes itself through
# sudo, but keeps every artefact and every manjaro-tools config file inside
# this directory (work/), so nothing is written to ~/.config or /var/lib.
#
# Every Qt .ts catalog under the profile is recompiled to .qm before buildiso
# runs, so translation files are never compiled by hand.

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

# NPBackup is not packaged for Manjaro/Arch. Its prebuilt Linux bundles are
# downloaded into vendor/ (git-ignored) and copied into the image through the
# opt/npbackup symlink in the desktop overlay. Pin the release and checksums
# so a build cannot silently pick up different binaries.
# Use upstream's x64 legacy builds: the regular binaries need newer CPU
# features than the default QEMU guest and some older physical machines have.
NPBACKUP_VERSION="${NPBACKUP_VERSION:-3.0.4}"
NPBACKUP_CLI_SHA256="${NPBACKUP_CLI_SHA256:-78df4559e7d32e1f4edeb5d403d75e61105dfae20053dca87306f9f2c388fa5f}"
NPBACKUP_GUI_SHA256="${NPBACKUP_GUI_SHA256:-c231f6abd711504554e458ac50a363d09627e0f6431f1e51c36cef6e456ae909}"
NPBACKUP_VENDOR_DIR="$SCRIPT_DIR/vendor/npbackup"

DO_CLEAN=false
DO_CHECK=false
NO_CHECK=false

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
      --check              only verify host tools and profile packages, then exit
      --no-check           do not verify profile packages before building
      --clean              remove out/ and work/, then exit
  -h, --help               show this help

Every run builds the complete ISO from scratch. There is no incremental or
resume mode.

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
    [unsquashfs]=squashfs-tools
    [cmp]=diffutils
    [grub-mkstandalone]=grub
    [pacman]=pacman
    [rsync]=rsync
    [openssl]=openssl
    [curl]=curl
    [git]=git
    [qemu-system-x86_64]=qemu-base
    [qemu-img]=qemu-base
)

# The package preflight normally resolves against the host's pacman databases.
# A profile user-repos.conf adds third-party repositories the host does not
# know about, so build a throwaway pacman config/database for the preflight
# instead of modifying the host's pacman setup.
CHECK_PACMAN_CONF=""
CHECK_PACMAN_DIR=""

prepare_check_pacman() {
    local user_conf="$PROFILE_DIR/user-repos.conf"
    local host_conf=/etc/pacman.conf
    local arch repo server url db f arch_line user_repos_ok=true

    CHECK_PACMAN_CONF=""
    CHECK_PACMAN_DIR=""

    [[ -r $user_conf && -r $host_conf ]] || return 0
    command -v pacman >/dev/null 2>&1 || return 0
    command -v curl >/dev/null 2>&1 || return 0

    CHECK_PACMAN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/local-host-check.XXXXXX") || {
        CHECK_PACMAN_DIR=""
        return 0
    }
    mkdir -p "$CHECK_PACMAN_DIR/sync" || { CHECK_PACMAN_DIR=""; return 0; }

    # Reuse the host's already-synced official databases.
    for f in /var/lib/pacman/sync/*.db /var/lib/pacman/sync/*.files; do
        [[ -e $f ]] || continue
        ln -s "$f" "$CHECK_PACMAN_DIR/sync/" 2>/dev/null || true
    done

    # Fetch each extra repository's database into the temporary DBPath.
    arch=$(uname -m)
    while read -r repo server; do
        [[ -n $repo && -n $server ]] || continue
        url=${server//\$repo/$repo}
        url=${url//\$arch/$arch}
        db="$CHECK_PACMAN_DIR/sync/$repo.db"
        # The host sync directory may already contain this repository (or a
        # symlink to it); never write through that. Remove it first.
        rm -f -- "$db"
        if curl -fsSL --max-time 30 -o "$db" "$url/$repo.db"; then
            info "ok       [$repo] database"
        else
            warn "could not download [$repo] database from $url"
            rm -f -- "$db"
            user_repos_ok=false
        fi
    done < <(awk '
        /^[[:space:]]*\[/ {
            repo = $0
            sub(/^[[:space:]]*\[/, "", repo)
            sub(/\][[:space:]]*$/, "", repo)
        }
        /^[[:space:]]*Server[[:space:]]*=/ {
            server = $0
            sub(/^[^=]*=[[:space:]]*/, "", server)
            sub(/[[:space:]]+$/, "", server)
            if (repo != "" && server != "") print repo, server
        }
    ' "$user_conf")

    grep -qE '^[[:space:]]*Architecture[[:space:]]*=' "$host_conf" \
        && arch_line="" || arch_line="Architecture = auto"

    awk -v archline="$arch_line" \
        -v dbpath="$CHECK_PACMAN_DIR/" \
        -v logfile="$CHECK_PACMAN_DIR/pacman.log" '
        /^\[options\]/ { in_options = 1; print; next }
        in_options && /^\[/ {
            if (archline != "") print archline
            print "DBPath = " dbpath
            print "LogFile = " logfile
            in_options = 0
        }
        { print }
        END {
            if (in_options) {
                if (archline != "") print archline
                print "DBPath = " dbpath
                print "LogFile = " logfile
            }
        }
    ' "$host_conf" > "$CHECK_PACMAN_DIR/pacman.conf" || {
        CHECK_PACMAN_DIR=""
        return 0
    }
    if $user_repos_ok; then
        cat "$user_conf" >> "$CHECK_PACMAN_DIR/pacman.conf" || {
            CHECK_PACMAN_DIR=""
            return 0
        }
    else
        warn "user repositories omitted from the preflight check"
    fi
    CHECK_PACMAN_CONF="$CHECK_PACMAN_DIR/pacman.conf"
}

check_pacman() {
    if [[ -n $CHECK_PACMAN_CONF ]]; then
        pacman --config "$CHECK_PACMAN_CONF" "$@"
    else
        pacman "$@"
    fi
}


run_checks() {
    local rc=0 missing=() pkg code

    msg "Build requirements"

    for pkg in buildiso xorriso mktorrent kwalify mkfs.fat mksquashfs \
               unsquashfs cmp \
               grub-mkstandalone grub-mkimage grub-editenv pacman rsync \
               openssl curl perl git; do
        if command -v "$pkg" >/dev/null 2>&1; then
            info "ok       $pkg"
        else
            info "MISSING  $pkg  (package: ${CMD_PACKAGE[$pkg]:-unknown})"
            rc=1
        fi
    done

    if command -v lrelease6 >/dev/null 2>&1 || command -v lrelease >/dev/null 2>&1; then
        info "ok       lrelease (translation catalogs)"
    else
        info "MISSING  lrelease  (package: qt6-tools)"
        rc=1
    fi

    for pkg in /usr/lib/manjaro-tools/util-yaml.sh \
               /usr/lib/manjaro-tools/util-iso.sh \
               /usr/lib/manjaro-tools/util-iso-image.sh \
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
        prepare_check_pacman
        if check_pacman -Si "$KERNEL" >/dev/null 2>&1; then
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
                check_pacman -Sp --print-format '%n' "$pkg" >/dev/null 2>&1 \
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

    if [[ -n $CHECK_PACMAN_DIR ]]; then
        rm -rf -- "$CHECK_PACMAN_DIR"
        CHECK_PACMAN_DIR=""
        CHECK_PACMAN_CONF=""
    fi

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

# Fetch the pinned NPBackup prebuilt bundles into vendor/npbackup. The profile
# contains a symlink at desktop-overlay/opt/npbackup, so buildiso's cp -LR
# dereferences it and copies the binaries into the image. Keeping the bundles
# under vendor/ means no large binaries are committed to git.
prepare_npbackup() {
    local dir="$NPBACKUP_VENDOR_DIR"
    local marker="$dir/.version"
    local base="https://github.com/netinvent/npbackup/releases/download/v$NPBACKUP_VERSION"
    local tmp cli_url gui_url

    if [[ -x "$dir/cli/npbackup-cli" && -x "$dir/gui/npbackup-gui" ]] \
        && [[ "$(cat "$marker" 2>/dev/null)" == \
              "$NPBACKUP_VERSION $NPBACKUP_CLI_SHA256 $NPBACKUP_GUI_SHA256" ]]; then
        info "ok       NPBackup $NPBACKUP_VERSION already vendored"
        return 0
    fi

    msg "Vendoring NPBackup $NPBACKUP_VERSION"
    tmp=$(mktemp -d "$WORK_DIR/tmp/npbackup.XXXXXX") \
        || die "cannot create a temporary directory for NPBackup"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$tmp'" RETURN

    cli_url="$base/npbackup-linux-x64-legacy-cli-public.tar.gz"
    gui_url="$base/npbackup-linux-x64-legacy-gui-public.tar.gz"

    curl -fL --retry 3 --connect-timeout 15 -o "$tmp/cli.tar.gz" "$cli_url" \
        || die "cannot download NPBackup CLI $NPBACKUP_VERSION"
    curl -fL --retry 3 --connect-timeout 15 -o "$tmp/gui.tar.gz" "$gui_url" \
        || die "cannot download NPBackup GUI $NPBACKUP_VERSION"

    printf '%s  %s\n' "$NPBACKUP_CLI_SHA256" "$tmp/cli.tar.gz" \
        | sha256sum -c - >/dev/null \
        || die "NPBackup CLI checksum mismatch"
    printf '%s  %s\n' "$NPBACKUP_GUI_SHA256" "$tmp/gui.tar.gz" \
        | sha256sum -c - >/dev/null \
        || die "NPBackup GUI checksum mismatch"

    mkdir -p "$tmp/cli" "$tmp/gui"
    tar -xzf "$tmp/cli.tar.gz" -C "$tmp/cli"
    tar -xzf "$tmp/gui.tar.gz" -C "$tmp/gui"
    [[ -x "$tmp/cli/npbackup-cli/npbackup-cli" ]] \
        || die "unexpected NPBackup CLI archive layout"
    [[ -x "$tmp/gui/npbackup-gui/npbackup-gui" ]] \
        || die "unexpected NPBackup GUI archive layout"

    rm -rf -- "$dir"
    mkdir -p "$dir"
    mv "$tmp/cli/npbackup-cli" "$dir/cli"
    mv "$tmp/gui/npbackup-gui" "$dir/gui"
    chmod -R u+rwX,go+rX "$dir"
    printf '%s %s %s\n' "$NPBACKUP_VERSION" "$NPBACKUP_CLI_SHA256" \
        "$NPBACKUP_GUI_SHA256" > "$marker"
    info "ok       NPBackup $NPBACKUP_VERSION"
}

# Rebuild every Qt translation catalog in the profile. The .qm is written next
# to its .ts, so the normal overlay copy puts it into the image. This runs on
# every build, not just when a timestamp looks stale.
compile_translations() {
    local lrelease ts qm tmp count=0
    local -a catalogs=()

    while IFS= read -r -d '' ts; do
        catalogs+=("$ts")
    done < <(find "$PROFILE_DIR" -type f -name '*.ts' -print0 | sort -z)

    ((${#catalogs[@]})) || return 0

    if command -v lrelease6 >/dev/null 2>&1; then
        lrelease=lrelease6
    elif command -v lrelease >/dev/null 2>&1; then
        lrelease=lrelease
    else
        die "lrelease6/lrelease is required to rebuild ${#catalogs[@]} translation catalog(s); install qt6-tools"
    fi

    msg "Compiling translation catalogs"
    for ts in "${catalogs[@]}"; do
        qm=${ts%.ts}.qm
        tmp="${qm}.tmp.$$"
        rm -f -- "$tmp"
        if ! "$lrelease" -silent "$ts" -qm "$tmp"; then
            rm -f -- "$tmp"
            die "failed to compile translation catalog: $ts"
        fi
        chmod 0644 "$tmp"
        if [[ -f $qm ]] && cmp -s "$tmp" "$qm"; then
            # Unchanged: match the source mtime so a --resume build does not
            # invalidate a cached image.
            touch -r "$ts" "$tmp"
        else
            # New content: make sure stale-image detection notices it.
            touch "$tmp"
        fi
        mv -f -- "$tmp" "$qm"
        # The build runs as root; keep the generated catalog owned by the
        # invoking user like the rest of the profile.
        chown "$RUN_UID:$RUN_GID" "$qm" 2>/dev/null || true
        info "rebuilt ${qm#"$PROFILE_DIR"/}"
        count=$((count + 1))
    done
    info "$count catalog(s)"
}

# manjaro-tools' clean_up_image() ends with a full-tree find over the chroot:
#
#   find "$1" -name *.pacnew -name *.pacsave -name *.pacorig -delete
#
# make_image_root() calls that while /proc, /sys and /dev are still mounted.
# find then descends into /proc, races with processes exiting, and aborts the
# build with "Invalid argument" / "No such file or directory". The three
# -name tests are also ANDed, so the original line deletes nothing.
#
# Patch it in place to stay on one filesystem and to match any of the three
# suffixes. This is the same kind of build-time manjaro-tools patch used by
# other derivative build scripts.
patch_manjaro_tools() {
    local image=/usr/lib/manjaro-tools/util-iso-image.sh

    [[ -r $image ]] || {
        warn "manjaro-tools util-iso-image.sh not found; not patching clean_up_image"
        return 0
    }

    if grep -qF 'find "$1" -xdev' "$image"; then
        info "ok       clean_up_image already skips other filesystems"
        return 0
    fi

    # Use variables so Perl does not interpolate the literal $1 in the
    # upstream line. \Q quotes the pattern text as-is. This also fixes the
    # ANDed -name tests so any pacnew/pacsave/pacorig file is deleted.
    perl -0pi -e 'my $old = q{find "$1" -name *.pacnew -name *.pacsave -name *.pacorig -delete}; my $new = q{find "$1" -xdev \\( -name "*.pacnew" -o -name "*.pacsave" -o -name "*.pacorig" \\) -delete}; s/\Q$old\E/$new/;' "$image" \
        || warn "could not run the clean_up_image patch on $image"

    # Fallback for a changed upstream line: -xdev is the important part;
    # it keeps find out of /proc, /sys, /dev and /run.
    if ! grep -qF 'find "$1" -xdev' "$image"; then
        sed -i 's|find "\$1"|find "\$1" -xdev|' "$image" \
            || warn "could not add -xdev to $image"
    fi

    if grep -qF 'find "$1" -xdev' "$image"; then
        info "patched  clean_up_image: skip pseudo-filesystems"
    else
        warn "clean_up_image find line was not patched; the build may fail in make_image_root"
    fi
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

    while :; do
        local -a args=("${base[@]}")
        local attempt_log="$log.attempt-$attempt"

        msg "Running buildiso from scratch (attempt $attempt/$BUILD_RETRIES)"
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
            info "Re-run the build from scratch after fixing the cause."
            return "$rc"
        fi

        if grep -qiE 'failed retrieving file|failed to retrieve|download library error|connection timed out|could not resolve|operation too slow|failed to download' "$attempt_log"; then
            rm -f "$attempt_log"
            attempt=$((attempt + 1))
            warn "download failure; retrying from scratch in $((attempt * 5))s (attempt $attempt/$BUILD_RETRIES)"
            sleep $((attempt * 5))
        else
            rm -f "$attempt_log"
            warn "buildiso failed (exit $rc); log: $log"
            info "Re-run the build from scratch after fixing the cause."
            return "$rc"
        fi
    done
}

latest_iso() {
    find "$OUT_DIR" -type f -name '*.iso' -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -n 1 | cut -d' ' -f2-
}

# Verify that the livefs really received the compatibility partition job.
# A stale/unapplied overlay would otherwise produce an image that Calamares
# refuses to start because bootloader requires a module named "partition".
verify_calamares_compat() {
    local desc="$WORK_DIR/chroots/$PROFILE/x86_64/livefs/usr/lib/calamares/modules/partition/module.desc"
    local settings="$WORK_DIR/chroots/$PROFILE/x86_64/livefs/etc/xdg/calamares/settings.conf"
    if [[ ! -r $desc ]]; then
        warn "cannot verify partition compatibility module at $desc"
        return 0
    fi
    if ! grep -q '^type:[[:space:]]*"job"' "$desc"; then
        die "livefs partition module is still the stock viewmodule; overlay was not applied"
    fi
    info "ok       Calamares partition compatibility job is present"

    if [[ -r $settings ]]; then
        local marker
        for marker in \
            'instances:' \
            'packagechooserq@local-partition' \
            'packagechooserq@data' \
            'packagechooserq@data-confirm' \
            'packagechooserq@backup-secondary' \
            '        - partition' \
            'local-host-setup-storage' \
            'data-fstab' \
            'local-host-setup-secondary-backup'; do
            grep -qF -- "$marker" "$settings" \
                || die "livefs Calamares settings is missing: $marker"
        done
        info "ok       Calamares local-host settings are present"
    else
        warn "cannot verify Calamares settings at $settings"
    fi
}

# Every file from the profile overlays must be in the image built from it.
# The check reads the squashfs files that buildiso leaves in its ISO staging
# directory, so it validates the real images and not just the chroots.
verify_profile_overlays() {
    local sfs_dir="$WORK_DIR/chroots/$PROFILE/iso/manjaro/x86_64"
    local checker="$SCRIPT_DIR/test/check-overlay-files.sh"

    [[ -r $checker ]] || die "missing overlay checker: $checker"
    [[ -d $sfs_dir ]] || die "cannot verify overlays: $sfs_dir is missing"

    msg "Verifying profile overlays"
    bash "$checker" "$sfs_dir" "$PROFILE_DIR" \
        || die "built images do not contain every file from the profile overlays"
}

# buildiso always writes the same filename. Give every successful build a
# unique name so an old ISO can never be mistaken for the one just built.
unique_iso_name() {
    local iso base stamp
    iso=$(latest_iso)
    [[ -n $iso ]] || return 0

    if [[ $(basename "$iso") =~ -b[0-9]{8}T[0-9]{6}Z\.iso$ ]]; then
        return 0
    fi

    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    base="${iso%.iso}"
    mv -- "$iso" "${base}-b${stamp}.iso" \
        || die "cannot rename $iso to a unique name"
    info "Unique ISO name: ${base}-b${stamp}.iso"
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
    patch_manjaro_tools
    prepare_npbackup
    compile_translations
    run_build
    verify_profile_overlays
    verify_calamares_compat

    unique_iso_name

    local iso
    iso=$(latest_iso)
    [[ -n $iso ]] || die "buildiso finished but no ISO was found under $OUT_DIR"

    printf '\n'
    msg "ISO ready"
    info "$iso"
    info "size: $(du -h -- "$iso" | cut -f1)"
    info "sha256: $(sha256sum -- "$iso" | cut -d' ' -f1)"
    printf '\n'
    info "Boot it with: $SCRIPT_DIR/run-vm.sh \"$iso\""
}

main "$@"
