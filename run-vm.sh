#!/usr/bin/env bash
#
# Boot the local-host-arch ISO or an installed system in QEMU.
#
# Defaults: 4 GiB RAM, 4 vCPUs, KVM if available, UEFI (OVMF), user-mode
# networking, the newest ISO and a persistent work/vm/disk.qcow2 install
# target. If QEMU has no gtk/sdl backend it starts a VNC server instead and
# prints how to connect.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
OUT_DIR="$SCRIPT_DIR/out"
PROFILES_DIR="$SCRIPT_DIR/iso-profiles"
VM_DIR="$SCRIPT_DIR/work/vm"

ISO=""
MEMORY="${VM_MEMORY:-4096}"
CPUS="${VM_CPUS:-4}"
DISK="${VM_DISK:-}"
DISK_SIZE="${VM_DISK_SIZE:-64G}"
EXTRA_DISK_COUNT="${VM_EXTRA_DISKS:-2}"
EXTRA_DISK_SIZE="${VM_EXTRA_DISK_SIZE:-64G}"
EXTRA_DISK_FORMAT="${VM_EXTRA_DISK_FORMAT:-ext4}"
EXTRA_DISKS=()
EXTRA_DISKS_EXPLICIT=false
NO_EXTRA_DISKS=false
RESET_DATA=false
NO_DISK=false
BOOT_MODE="${VM_BOOT:-iso}"
RESET_INSTALL=false
KEEP_INSTALL=false
EXPLICIT_RESET=false
FIRMWARE="uefi"
DISPLAY_MODE="${VM_DISPLAY:-auto}"
VNC_ADDR="${VM_VNC:-127.0.0.1:0}"
SNAPSHOT=false
display_desc=""

msg()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

reset_install() {
    msg "Removing existing install"
    if pgrep -f 'qemu-system-x86_64' >/dev/null 2>&1; then
        die "a QEMU VM is running; shut it down before resetting the install"
    fi
    # Extra data disks are deliberately left alone: reinstalling the system
    # must not wipe the /data test disks.
    local f removed=false
    for f in "$DISK" "$VM_DIR/OVMF_VARS.fd"; do
        if [[ -e $f ]]; then
            rm -f -- "$f" || die "cannot remove $f; run ./build.sh once (fixes ownership) or remove it with sudo"
            info "removed $f"
            removed=true
        fi
    done
    $removed || info "no existing install found"
}

# Create a qcow2 data disk already containing an ext4 filesystem. A sparse
# raw image is formatted with mkfs.ext4 (which understands regular files)
# and then converted; no root, loop device or qemu-nbd is needed.
create_extra_disk() {
    local path=$1 label=$2 format=${3:-ext4} raw
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found (package: qemu-base)"

    mkdir -p "$(dirname -- "$path")" || die "cannot create directory for $path"
    if [[ $format == none ]]; then
        qemu-img create -f qcow2 "$path" "$EXTRA_DISK_SIZE" >/dev/null
        return
    fi

    command -v mkfs.ext4 >/dev/null 2>&1 || die "mkfs.ext4 not found (package: e2fsprogs)"
    command -v truncate >/dev/null 2>&1 || die "truncate not found (package: coreutils)"

    raw=$(mktemp "${path}.raw.XXXXXX") || die "cannot create a temporary image for $path"
    if ! truncate -s "$EXTRA_DISK_SIZE" "$raw"; then
        rm -f -- "$raw"
        die "cannot size $raw to $EXTRA_DISK_SIZE"
    fi
    if ! mkfs.ext4 -q -F -L "$label" "$raw"; then
        rm -f -- "$raw"
        die "cannot create an ext4 filesystem in $raw"
    fi
    if ! qemu-img convert -f raw -O qcow2 "$raw" "$path"; then
        rm -f -- "$raw"
        die "cannot convert $raw to $path"
    fi
    rm -f -- "$raw"
}

usage() {
    cat <<EOF
Usage: ${0##*/} [options] [ISO]

Boots an ISO built by build.sh (default) or an installed system, and always
attaches a disk by default so the live session can install to it.

Options:
  -m, --memory MB        RAM in MiB (default: $MEMORY)
  -c, --cpus N           number of vCPUs (default: $CPUS)
      --disk FILE        attach/create a qcow2 disk (default: $VM_DIR/disk.qcow2)
      --no-disk          boot without an install disk
      --disk-size SIZE   size for a newly created install disk (default: $DISK_SIZE)
      --extra-disks N    number of default data disks (default: $EXTRA_DISK_COUNT)
      --extra-disk FILE  attach an extra qcow2 data disk (repeatable; overrides
                         the default data disks)
      --extra-disk-size SIZE  size for newly created data disks (default: $EXTRA_DISK_SIZE)
      --extra-disk-format FORMAT  format for newly created data disks (default: $EXTRA_DISK_FORMAT;
                         existing images are never modified)
      --reset-data       delete the data disks so they are recreated
      --no-extra-disks   do not attach the default data disks
      --boot MODE        boot the live "iso" or the installed disk (default: $BOOT_MODE)
      --reset-install    delete the install disk and UEFI vars, then boot fresh
                         (extra data disks are kept; never happens automatically)
      --keep-install     kept for compatibility; the install is never reset
                         automatically anymore
      --bios             legacy SeaBIOS instead of UEFI/OVMF
      --display MODE     auto, gtk, sdl, vnc or none (gtk/sdl are optional; default: $DISPLAY_MODE)
      --vnc ADDR         VNC listen address, e.g. 127.0.0.1:1 (default: $VNC_ADDR)
      --snapshot         discard all guest writes when QEMU exits
  -h, --help             show this help

Environment:
  VM_MEMORY, VM_CPUS, VM_DISK, VM_DISK_SIZE, VM_EXTRA_DISKS,
  VM_EXTRA_DISK_SIZE, VM_EXTRA_DISK_FORMAT, VM_BOOT, VM_DISPLAY, VM_VNC

Install: boot the ISO, follow the installer, pick /dev/vda.
The default install disk is $DISK_SIZE; each default data disk is
$EXTRA_DISK_SIZE. Existing images keep their old size. Use
--reset-install to recreate the system disk and --reset-data to recreate
the data disks at the current defaults, or pass --disk-size /
--extra-disk-size explicitly.
The two default data disks are /dev/vdb and /dev/vdc, preformatted ext4
with labels DATA1 and DATA2, so they appear in the installer's Data
storage step. Use --extra-disks N, --extra-disk FILE or --no-extra-disks
to change them.
For btrfs RAID testing, select two or more whole disks and choose btrfs on
the confirmation step; the RAID level defaults to the highest the data disks
support (RAID1 for 2, RAID1C3 for 3, RAID10 for 4+) and can be lowered.
f2fs and ext4 are available only for a single /data device.
With two or more whole disks, the confirmation step can assign one selected
disk as the restic backup disk; the remaining disks become /data. The /data and
backup filesystems are chosen independently, so btrfs RAID for /data with an
f2fs backup disk is a valid combination. With only two disks this is one data
disk plus one backup disk; add a third disk for RAID1 plus a dedicated backup
disk.
Use --reset-data --extra-disk-format none only if you explicitly want to
delete and recreate the data disk images as blank disks.
Then boot the installed system with: ${0##*/} --boot installed
Live session login: manjaro / manjaro
EOF
}

while (($#)); do
    case "$1" in
        -m|--memory)      MEMORY="${2:?missing value for $1}"; shift 2 ;;
        -c|--cpus)        CPUS="${2:?missing value for $1}"; shift 2 ;;
        --disk)           DISK="${2:?missing value for $1}"; shift 2 ;;
        --no-disk)        NO_DISK=true; shift ;;
        --disk-size)      DISK_SIZE="${2:?missing value for $1}"; shift 2 ;;
        --extra-disks)    EXTRA_DISK_COUNT="${2:?missing value for $1}"; shift 2 ;;
        --extra-disk)     EXTRA_DISKS+=("${2:?missing value for $1}"); EXTRA_DISKS_EXPLICIT=true; shift 2 ;;
        --extra-disk-size) EXTRA_DISK_SIZE="${2:?missing value for $1}"; shift 2 ;;
        --extra-disk-format) EXTRA_DISK_FORMAT="${2:?missing value for $1}"; shift 2 ;;
        --reset-data)     RESET_DATA=true; shift ;;
        --no-extra-disks) NO_EXTRA_DISKS=true; shift ;;
        --boot)           BOOT_MODE="${2:?missing value for $1}"; shift 2 ;;
        --reset-install)  RESET_INSTALL=true; EXPLICIT_RESET=true; shift ;;
        --keep-install)   KEEP_INSTALL=true; shift ;;
        --bios)           FIRMWARE="bios"; shift ;;
        --display)        DISPLAY_MODE="${2:?missing value for $1}"; shift 2 ;;
        --vnc)            VNC_ADDR="${2:?missing value for $1}"; shift 2 ;;
        --snapshot)       SNAPSHOT=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        --)               shift; break ;;
        -*)               usage >&2; die "unknown argument: $1" ;;
        *)                ISO="$1"; shift ;;
    esac
done

command -v qemu-system-x86_64 >/dev/null 2>&1 \
    || die "qemu-system-x86_64 not found (package: qemu-base)"

case "$BOOT_MODE" in
    iso|installed) ;;
    *) die "unsupported boot mode: $BOOT_MODE (use iso or installed)" ;;
esac

[[ $EXTRA_DISK_COUNT =~ ^[0-9]+$ ]] \
    || die "invalid data disk count: $EXTRA_DISK_COUNT (use a non-negative integer)"

case $EXTRA_DISK_FORMAT in
    ext4|none) ;;
    blank) EXTRA_DISK_FORMAT="none" ;;
    *) die "invalid data disk format: $EXTRA_DISK_FORMAT (use ext4 or none)" ;;
esac

# Never recreate an existing data disk just because a format was requested:
# the file may be a hand-prepared image. Only --reset-data deletes data disks.

if $NO_DISK && [[ $BOOT_MODE == "installed" ]]; then
    die "--boot installed needs a disk (remove --no-disk)"
fi

if $RESET_INSTALL && $KEEP_INSTALL; then
    die "--reset-install and --keep-install are mutually exclusive"
fi

if $RESET_INSTALL; then
    $NO_DISK && die "--reset-install needs a disk (remove --no-disk)"
    [[ $BOOT_MODE == "installed" ]] && die "--reset-install cannot be combined with --boot installed"
fi

if $NO_DISK; then
    DISK=""
fi

if ! $NO_DISK && [[ -z $DISK ]]; then
    DISK="$VM_DIR/disk.qcow2"
fi
mkdir -p "$VM_DIR" 2>/dev/null || die "cannot create $VM_DIR"
[[ -w $VM_DIR ]] || die "$VM_DIR is not writable; run ./build.sh once (it fixes ownership) or chown it to $(id -u):$(id -g)"

# Default extra data disks live next to the install disk. Explicit
# --extra-disk paths replace the default set; --no-extra-disks disables only
# the defaults, so explicitly named disks are still attached.
if ! $NO_EXTRA_DISKS && ! $EXTRA_DISKS_EXPLICIT; then
    for ((i = 1; i <= EXTRA_DISK_COUNT; i++)); do
        EXTRA_DISKS+=("$VM_DIR/data${i}.qcow2")
    done
fi

if [[ -n $DISK ]]; then
    for extra in "${EXTRA_DISKS[@]}"; do
        [[ $extra == "$DISK" ]] && die "data disk is also the install disk: $extra"
    done
fi
if ((${#EXTRA_DISKS[@]})); then
    declare -A seen_extra=()
    for extra in "${EXTRA_DISKS[@]}"; do
        [[ -z ${seen_extra[$extra]:-} ]] || die "data disk listed more than once: $extra"
        seen_extra[$extra]=1
    done
    unset seen_extra
fi

if $RESET_DATA; then
    if pgrep -f 'qemu-system-x86_64' >/dev/null 2>&1; then
        die "a QEMU VM is running; shut it down before resetting data disks"
    fi
    removed=false
    for extra in "${EXTRA_DISKS[@]}"; do
        if [[ -e $extra ]]; then
            rm -f -- "$extra" || die "cannot remove $extra"
            info "removed $extra"
            removed=true
        fi
    done
    $removed || info "no data disks to reset"
    unset removed
fi

if $RESET_INSTALL && $EXPLICIT_RESET; then
    reset_install
fi

# The install disk is never reset automatically. Use --reset-install when a
# fresh target is explicitly wanted; otherwise booting the ISO leaves the
# installed system intact.

if [[ $BOOT_MODE == "iso" ]]; then
    if [[ -z $ISO ]]; then
        mapfile -t isos < <(
            find "$OUT_DIR" -type f -name '*.iso' -printf '%T@ %p\n' 2>/dev/null \
                | sort -n | cut -d' ' -f2-
        )
        ((${#isos[@]})) || die "no ISO found under $OUT_DIR; run ./build.sh first"

        # Prefer build-stamped ISOs (-bYYYYMMDDTHHMMSSZ.iso). Those are only
        # created after a successful build. A fixed-name ISO left behind by a
        # failed/interrupted build can be a partial file and must not win just
        # because it has a newer mtime.
        stamped=()
        for candidate in "${isos[@]}"; do
            [[ $(basename "$candidate") =~ -b[0-9]{8}T[0-9]{6}Z\.iso$ ]] \
                && stamped+=("$candidate")
        done
        if ((${#stamped[@]})); then
            ISO="${stamped[-1]}"
        else
            ISO="${isos[-1]}"
        fi
    fi

    [[ -f $ISO ]] || die "ISO not found: $ISO"
    [[ -s $ISO ]] || die "ISO is empty: $ISO"
    iso_bytes=$(stat -c %s "$ISO" 2>/dev/null || echo 0)
    if ((iso_bytes < 100 * 1024 * 1024)); then
        die "ISO looks incomplete ($iso_bytes bytes): $ISO"
    fi
    info "iso size: $(du -h -- "$ISO" | cut -f1)"

    newer_profile=$(find "$PROFILES_DIR" -type f -newer "$ISO" -print -quit 2>/dev/null || true)
    if [[ -n $newer_profile ]]; then
        printf 'WARNING: this ISO predates profile changes:\n' >&2
        printf '         %s\n' "$newer_profile" >&2
        printf '         Rebuild it (./build.sh --resume) or boot an older layout.\n' >&2
    fi
else
    [[ -n $DISK ]] || die "--boot installed needs a disk"
    [[ -f $DISK ]] || die "installed disk not found: $DISK (install the system first)"
    disk_bytes=$(stat -c %s "$DISK" 2>/dev/null || echo 0)
    if ((disk_bytes < 10 * 1024 * 1024)); then
        die "install disk $DISK looks empty; boot the ISO and install first, or use --reset-install only when you want to discard it"
    fi
    if [[ -n $ISO ]]; then
        info "ignoring ISO argument in --boot installed mode"
        ISO=""
    fi
fi

if $SNAPSHOT; then
    printf 'WARNING: --snapshot discards the installation when QEMU exits.\n' >&2
fi

accel="tcg"
cpu="max"
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    accel="kvm"
    cpu="host"
else
    msg "WARNING: /dev/kvm is not accessible, using TCG (very slow)"
fi

args=(
    -name "local-host-arch"
    -machine "q35,accel=$accel"
    -cpu "$cpu"
    -smp "$CPUS"
    -m "$MEMORY"
    -device qemu-xhci
    -device usb-tablet
    -netdev "user,id=net0"
    -device "virtio-net-pci,netdev=net0"
    -rtc base=utc
)

if [[ $BOOT_MODE == "iso" ]]; then
    args+=(-boot "menu=on,order=d" -cdrom "$ISO")
else
    args+=(-boot "menu=on,order=c")
fi

if [[ $FIRMWARE == "uefi" ]]; then
    OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
    OVMF_VARS_TEMPLATE="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
    [[ -r $OVMF_CODE ]] || die "missing $OVMF_CODE (package: edk2-ovmf)"
    [[ -r $OVMF_VARS_TEMPLATE ]] || die "missing $OVMF_VARS_TEMPLATE (package: edk2-ovmf)"

    mkdir -p "$VM_DIR"
    OVMF_VARS="$VM_DIR/OVMF_VARS.fd"
    [[ -f $OVMF_VARS ]] || cp -- "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"

    args+=(
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$OVMF_VARS"
    )
fi

if [[ -n $DISK ]]; then
    if [[ ! -e $DISK ]]; then
        command -v qemu-img >/dev/null 2>&1 \
            || die "qemu-img not found (package: qemu-base)"
        mkdir -p "$(dirname -- "$DISK")"
        msg "Creating $DISK_SIZE qcow2 disk at $DISK"
        qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
    fi
    args+=(-drive "file=$DISK,if=virtio,format=qcow2,cache=writeback")
fi

if ((${#EXTRA_DISKS[@]})); then
    extra_index=0
    for extra in "${EXTRA_DISKS[@]}"; do
        extra_index=$((extra_index + 1))
        if [[ ! -e $extra ]]; then
            if [[ $EXTRA_DISK_FORMAT == none ]]; then
                msg "Creating $EXTRA_DISK_SIZE blank data disk at $extra"
            else
                msg "Creating $EXTRA_DISK_SIZE ext4 data disk at $extra"
            fi
            create_extra_disk "$extra" "DATA${extra_index}" "$EXTRA_DISK_FORMAT"
        fi
        args+=(-drive "file=$extra,if=virtio,format=qcow2,cache=writeback")
    done
    unset extra_index extra
fi

if $SNAPSHOT; then args+=(-snapshot); fi

case "$DISPLAY_MODE" in
    auto)
        backends=$(qemu-system-x86_64 -display help 2>&1 || true)
        backend=""
        if grep -qw 'gtk' <<<"$backends"; then
            backend="gtk"
        elif grep -qw 'sdl' <<<"$backends"; then
            backend="sdl"
        fi
        # A GUI backend needs a session to draw on; fall back to VNC when
        # running without DISPLAY (ssh, headless shell, ...).
        if [[ -n $backend && ( -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ) ]]; then
            if [[ $backend == gtk ]]; then
                # Absolute usb-tablet input plus no hover-grab keeps the host
                # pointer usable. Ctrl+Alt+G still releases a manual grab.
                # Hide the QEMU menu bar ("Machine" controls); use the F10
                # shortcut if it is needed temporarily.
                args+=(-display "gtk,grab-on-hover=off,show-menubar=off")
            else
                args+=(-display "$backend")
            fi
            display_desc="$backend"
        else
            args+=(-vnc "$VNC_ADDR")
            display_desc="vnc $VNC_ADDR"
        fi
        ;;
    gtk)
        args+=(-display "gtk,grab-on-hover=off,show-menubar=off")
        display_desc="gtk"
        ;;
    sdl|none)
        args+=(-display "$DISPLAY_MODE")
        display_desc="$DISPLAY_MODE"
        ;;
    vnc)
        args+=(-vnc "$VNC_ADDR")
        display_desc="vnc $VNC_ADDR"
        ;;
    *)
        die "unsupported display mode: $DISPLAY_MODE (use auto, gtk, sdl, vnc or none)"
        ;;
esac

msg "Booting $BOOT_MODE mode"
info "firmware: $FIRMWARE"
info "accel:    $accel ($CPUS vCPU, ${MEMORY} MiB RAM)"
if [[ -n $DISK ]]; then info "disk:     $DISK"; fi
if ((${#EXTRA_DISKS[@]})); then
    info "data:     ${#EXTRA_DISKS[@]} extra disk(s) (new disks: $EXTRA_DISK_FORMAT)"
    for extra in "${EXTRA_DISKS[@]}"; do info "          $extra"; done
fi
if [[ $BOOT_MODE == "iso" ]]; then info "iso:      $ISO"; fi
if [[ " ${args[*]} " == *" -vnc "* ]]; then
    port=${VNC_ADDR##*:}
    info "display:  VNC on $VNC_ADDR (port 5900 + $port)"
    info "connect:  vncviewer ${VNC_ADDR%:*}:$((5900 + port))"
    info "          (install qemu-desktop for a native window)"
    info "release:  VNC viewer release key (F8 in TigerVNC, right Ctrl in Remmina)"
else
    info "display:  $display_desc"
    info "release:  Ctrl+Alt+G release input, Ctrl+Alt+F fullscreen, Ctrl+Alt+2 monitor"
fi
info "stop:     from another terminal: pkill qemu-system-x86_64"
if [[ $BOOT_MODE == "iso" ]]; then
    info "login:    manjaro / manjaro"
    info "install:  follow the installer, target /dev/vda"
    info "then:     ${0##*/} --boot installed"
fi
printf '\n'

msg "QEMU command"
info "${args[*]}"
printf '\n'

exec qemu-system-x86_64 "${args[@]}"
