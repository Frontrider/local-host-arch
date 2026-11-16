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
DISK_SIZE="${VM_DISK_SIZE:-25G}"
NO_DISK=false
BOOT_MODE="${VM_BOOT:-iso}"
FIRMWARE="uefi"
DISPLAY_MODE="${VM_DISPLAY:-auto}"
VNC_ADDR="${VM_VNC:-127.0.0.1:0}"
SNAPSHOT=false
display_desc=""

msg()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: ${0##*/} [options] [ISO]

Boots an ISO built by build.sh (default) or an installed system, and always
attaches a disk by default so the live session can install to it.

Options:
  -m, --memory MB        RAM in MiB (default: $MEMORY)
  -c, --cpus N           number of vCPUs (default: $CPUS)
      --disk FILE        attach/create a qcow2 disk (default: $VM_DIR/disk.qcow2)
      --no-disk          boot without a disk
      --disk-size SIZE   size for a newly created disk (default: $DISK_SIZE)
      --boot MODE        boot the live "iso" or the installed disk (default: $BOOT_MODE)
      --bios             legacy SeaBIOS instead of UEFI/OVMF
      --display MODE     auto, gtk, sdl, vnc or none (gtk/sdl are optional; default: $DISPLAY_MODE)
      --vnc ADDR         VNC listen address, e.g. 127.0.0.1:1 (default: $VNC_ADDR)
      --snapshot         discard all guest writes when QEMU exits
  -h, --help             show this help

Environment:
  VM_MEMORY, VM_CPUS, VM_DISK, VM_DISK_SIZE, VM_BOOT, VM_DISPLAY, VM_VNC

Install: boot the ISO, run Manjaro Hello -> Install, pick /dev/vda.
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
        --boot)           BOOT_MODE="${2:?missing value for $1}"; shift 2 ;;
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

if $NO_DISK && [[ $BOOT_MODE == "installed" ]]; then
    die "--boot installed needs a disk (remove --no-disk)"
fi

if $NO_DISK; then
    DISK=""
fi

if ! $NO_DISK && [[ -z $DISK ]]; then
    DISK="$VM_DIR/disk.qcow2"
fi
mkdir -p "$VM_DIR"

if [[ $BOOT_MODE == "iso" ]]; then
    if [[ -z $ISO ]]; then
        mapfile -t isos < <(
            find "$OUT_DIR" -type f -name '*.iso' -printf '%T@ %p\n' 2>/dev/null \
                | sort -n | cut -d' ' -f2-
        )
        ((${#isos[@]})) || die "no ISO found under $OUT_DIR; run ./build.sh first"
        ISO="${isos[-1]}"
    fi

    [[ -f $ISO ]] || die "ISO not found: $ISO"
    [[ -s $ISO ]] || die "ISO is empty: $ISO"

    newer_profile=$(find "$PROFILES_DIR" -type f -newer "$ISO" -print -quit 2>/dev/null || true)
    if [[ -n $newer_profile ]]; then
        printf 'WARNING: this ISO predates profile changes:\n' >&2
        printf '         %s\n' "$newer_profile" >&2
        printf '         Rebuild it (./build.sh --resume) or boot an older layout.\n' >&2
    fi
else
    [[ -n $DISK ]] || die "--boot installed needs a disk"
    [[ -f $DISK ]] || die "installed disk not found: $DISK (install the system first)"
    if [[ -n $ISO ]]; then
        info "ignoring ISO argument in --boot installed mode"
        ISO=""
    fi
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
            args+=(-display "$backend")
            display_desc="$backend"
        else
            args+=(-vnc "$VNC_ADDR")
            display_desc="vnc $VNC_ADDR"
        fi
        ;;
    gtk|sdl|none)
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
if [[ $BOOT_MODE == "iso" ]]; then info "iso:      $ISO"; fi
if [[ " ${args[*]} " == *" -vnc "* ]]; then
    port=${VNC_ADDR##*:}
    info "display:  VNC on $VNC_ADDR (port 5900 + $port)"
    info "connect:  vncviewer ${VNC_ADDR%:*}:$((5900 + port))"
    info "          (install qemu-desktop for a native window)"
else
    info "display:  $display_desc"
fi
if [[ $BOOT_MODE == "iso" ]]; then
    info "login:    manjaro / manjaro"
    info "install:  Manjaro Hello -> Install, target /dev/vda"
    info "then:     ${0##*/} --boot installed"
fi
printf '\n'

msg "QEMU command"
info "${args[*]}"
printf '\n'

exec qemu-system-x86_64 "${args[@]}"
