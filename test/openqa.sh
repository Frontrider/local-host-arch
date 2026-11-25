#!/usr/bin/env bash
# Run the local-host openQA stack with Docker Compose.
#
#   bash test/openqa.sh up             # build/start the stack and wait for the UI
#   bash test/openqa.sh prepare-needles # generate backup fixtures without Docker
#   bash test/openqa.sh schedule [iso] # schedule every test suite
#   bash test/openqa.sh schedule-suite NAME [iso]
#                                      # schedule only one test suite
#   bash test/openqa.sh schedule-data-drive [iso]
#                                      # install with a separate /data disk
#   bash test/openqa.sh schedule-backup-drive [iso]
#                                      # install with a data and backup disk
#   bash test/openqa.sh schedule-backup-only [iso]
#                                      # backup disk, data on the system disk
#   bash test/openqa.sh schedule-webdav-backup [iso]
#                                      # restore from a WebDAV mirror
#   bash test/openqa.sh schedule-data-backup-f2fs [iso]
#                                      # data and f2fs backup disks
#   bash test/openqa.sh schedule-raid1 [iso]
#   bash test/openqa.sh schedule-raid0 [iso]
#                                      # two data disks in RAID1 or RAID0
#   bash test/openqa.sh schedule-raid1-backup [iso]
#   bash test/openqa.sh schedule-raid1-backup-f2fs [iso]
#                                      # RAID1 data plus a backup disk
#   bash test/openqa.sh status
#   bash test/openqa.sh logs
#   bash test/openqa.sh down           # remove the container, keep the data
#   bash test/openqa.sh purge          # remove the container and delete the data
#
# test/openqa-distri/ and the ISO folder are bind-mounted into the container.
# The ISO folder holds all builds for the current base Manjaro image, so the
# ISOs are flat assets under the names openQA expects. The selected build is
# also exposed under the product asset name (ISO_NAME) with a hardlink, since
# openQA looks assets up by that name, not by the timestamped build filename.
# The version changes only every few months; update it below and in
# compose.yaml when the base image bumps.
#
# Environment overrides:
#   OPENQA_IMAGE          local image tag  (default: local-host-openqa:latest)
#   OPENQA_BASE_IMAGE     upstream image   (default: openQA single-instance)
#   OPENQA_NAME           container name   (default: local-host-openqa)
#   OPENQA_HTTP_PORT      host port for the web UI (default: 1080)
#   OPENQA_HTTPS_PORT     host port for HTTPS      (default: 1443)
#   OPENQA_DATA_VOLUME    volume for /var/lib/openqa (default: local-host-openqa-data)
#   OPENQA_PG_VOLUME      volume for /var/lib/pgsql  (default: local-host-openqa-pg)
#   OPENQA_API_KEY, OPENQA_API_SECRET  credentials for openqa-cli, if set
#
# The image is built from test/openqa/Dockerfile: the upstream single-instance
# image plus ffmpeg, so os-autoinst records a browser-playable WebM next to the
# Theora OGV it always writes. State is kept in named volumes; only `purge`
# deletes them. `down` keeps them, but the next `up` bootstraps from scratch
# because the one-time marker lives in the container.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
OUT_DIR="$REPO_ROOT/out"
DISTRI_DIR="$REPO_ROOT/test/openqa-distri"

NAME="${OPENQA_NAME:-local-host-openqa}"
IMAGE="${OPENQA_IMAGE:-local-host-openqa:latest}"
BASE_IMAGE="${OPENQA_BASE_IMAGE:-registry.opensuse.org/devel/openqa/containers/openqa-single-instance}"
HTTP_PORT="${OPENQA_HTTP_PORT:-1080}"
HTTPS_PORT="${OPENQA_HTTPS_PORT:-1443}"
DATA_VOLUME="${OPENQA_DATA_VOLUME:-local-host-openqa-data}"
PG_VOLUME="${OPENQA_PG_VOLUME:-local-host-openqa-pg}"
COMPOSE_PROJECT="${OPENQA_COMPOSE_PROJECT:-local-host-openqa}"
COMPOSE_FILE="$REPO_ROOT/test/openqa/compose.yaml"
# The base Manjaro image version; it changes only every few months. Keep the
# bind mount in compose.yaml in sync.
ISO_DIR="$OUT_DIR/manjaro/local-host/26.1.3"
# openQA's asset name for this product (DISTRI-VERSION-FLAVOR.ARCH). The build
# output keeps its own timestamped name, so schedule exposes the selected build
# under this name too. Keep in sync with scenario-definitions.yaml.
ISO_NAME="local-host-1-live.x86_64.iso"

# Compose interpolates these from the process environment.
export OPENQA_IMAGE="$IMAGE"
export OPENQA_BASE_IMAGE="$BASE_IMAGE"
export OPENQA_NAME="$NAME"
export OPENQA_HTTP_PORT="$HTTP_PORT"
export OPENQA_HTTPS_PORT="$HTTPS_PORT"
export OPENQA_DATA_VOLUME="$DATA_VOLUME"
export OPENQA_PG_VOLUME="$PG_VOLUME"
# Absolute paths so the bind mounts do not depend on the directory the script
# is called from.
export OPENQA_DISTRI_DIR="$DISTRI_DIR"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat >&2 <<EOF
Usage: ${0##*/} {up|status|logs|down|purge}
       ${0##*/} prepare-needles
       ${0##*/} schedule [iso]          # every test suite
       ${0##*/} schedule-suite NAME [iso]
       ${0##*/} schedule-data-drive [iso]
       ${0##*/} schedule-backup-drive [iso]
       ${0##*/} schedule-backup-only [iso]
       ${0##*/} schedule-webdav-backup [iso]
       ${0##*/} schedule-data-backup-f2fs [iso]
       ${0##*/} schedule-raid1 [iso]
       ${0##*/} schedule-raid0 [iso]
       ${0##*/} schedule-raid1-backup [iso]
       ${0##*/} schedule-raid1-backup-f2fs [iso]
EOF
    exit 2
}


if command -v docker >/dev/null 2>&1; then
    ENGINE=docker
elif command -v podman >/dev/null 2>&1; then
    ENGINE=podman
else
    die "docker or podman is required"
fi

compose() { "$ENGINE" compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" "$@"; }

"$ENGINE" compose version >/dev/null 2>&1 || die "$ENGINE compose is required"

newest_iso() {
    find "$ISO_DIR" -type f -name '*.iso' ! -name "$ISO_NAME" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -n 1 | cut -d' ' -f2-
}

iso_dir_of() {
    (cd -- "$(dirname -- "$1")" && pwd -P)
}

# openQA looks the ISO up by the asset name in the job setting, which is the
# product name, not the timestamped build filename. Expose the selected build
# under that name (a hardlink costs no space, and a copy is only used when the
# two names are on different filesystems).
expose_iso() {
    local iso=$1 name alias
    for name in "$ISO_NAME" "${ISO_NAME%.iso}"; do
        alias="$ISO_DIR/$name"
        # Drop an alias left by an older symlink-based version.
        [[ -L $alias ]] && rm -f -- "$alias"
        [[ $iso == "$alias" || $iso -ef $alias ]] && continue
        ln -f -- "$iso" "$alias" 2>/dev/null \
            || cp -p -- "$iso" "$alias" \
            || die "cannot expose $iso as $alias"
    done
}

wait_ready() {
    printf '==> Waiting for the openQA web UI\n'
    local i
    for ((i = 0; i < 300; i++)); do
        if compose exec -T openqa curl -fsS http://localhost/ >/dev/null 2>&1; then
            printf 'openQA web UI: http://localhost:%s\n' "$HTTP_PORT"
            printf 'openQA HTTPS:  https://localhost:%s\n' "$HTTPS_PORT"
            return 0
        fi
        sleep 2
    done
    die "openQA did not become ready; check the logs with 'bash $0 logs'"
}

up() {
    mkdir -p "$ISO_DIR"
    # The web UI runs as the openQA user inside the container; make the shared
    # needle directory writable so the needle editor can save straight into the
    # repository (git does not track these mode bits).
    chmod -R a+rwX "$DISTRI_DIR/needles" 2>/dev/null || true

    # Make the newest build available under the product asset name, so it can
    # also be picked in the web UI.
    local iso
    iso=$(newest_iso)
    if [[ -n $iso ]]; then
        expose_iso "$iso"
    fi

    compose up -d --build
    wait_ready
}

schedule_run() {
    local suite=""
    if [[ ${1:-} == --suite ]]; then
        suite=${2:?missing suite name}
        shift 2
    fi
    case "${1:-}" in
        --data-drive)
            suite=install-data-drive
            shift
            ;;
        --backup-drive)
            suite=install-backup-drive
            shift
            ;;
    esac

    local iso=${1:-}
    [[ -n $iso ]] || iso=$(newest_iso)
    [[ -n $iso ]] || die "no ISO found in $ISO_DIR; run ./build.sh first"
    [[ -f $iso ]] || die "ISO not found: $iso"
    [[ $(iso_dir_of "$iso") == "$ISO_DIR" ]] \
        || die "$iso is not in $ISO_DIR; move it there or update the mount"

    expose_iso "$iso"

    # Blank install and extra-disk images, created once and reused. They are
    # sparse, so creating the unused ones costs no real space.
    compose exec -T openqa sh -c '
        mkdir -p /var/lib/openqa/share/factory/hdd
        cd /var/lib/openqa/share/factory/hdd
        for disk in empty empty-data empty-backup empty-extra; do
            test -f "$disk.qcow2" ||
                qemu-img create -f qcow2 "$disk.qcow2" 20G
        done'

    local -a cli=(openqa-cli schedule --host http://localhost)
    if [[ -n ${OPENQA_API_KEY:-} && -n ${OPENQA_API_SECRET:-} ]]; then
        cli+=(--apikey "$OPENQA_API_KEY" --apisecret "$OPENQA_API_SECRET")
    fi

    # Keep these in sync with the job templates in scenario-definitions.yaml.
    # Passing them here also covers schedules that do not read template
    # settings. When no suite is selected, every job template is scheduled and
    # these per-suite settings come from the YAML itself.
    local -a suite_settings=()
    local -a test_setting=()
    case "$suite" in
        '') ;;
        install) test_setting=(TEST=install) ;;
        install-data-drive)
            test_setting=(TEST=install-data-drive)
            suite_settings=(HDD_2=empty-data.qcow2 NUMDISKS=2)
            ;;
        install-backup-only|install-webdav-backup)
            test_setting=(TEST="$suite")
            suite_settings=(HDD_2=empty-backup.qcow2 NUMDISKS=2)
            ;;
        install-backup-drive|install-data-backup-f2fs|install-raid1|install-raid0)
            test_setting=(TEST="$suite")
            suite_settings=(HDD_2=empty-data.qcow2 HDD_3=empty-backup.qcow2 NUMDISKS=3)
            ;;
        install-raid1-backup|install-raid1-backup-f2fs)
            test_setting=(TEST="$suite")
            suite_settings=(HDD_2=empty-data.qcow2 HDD_3=empty-backup.qcow2 HDD_4=empty-extra.qcow2 NUMDISKS=4)
            ;;
        *)
            die "unknown test suite: $suite"
            ;;
    esac

    printf '==> Scheduling %s (%s)\n' \
        "$(basename -- "$iso")" "${suite:-all test suites}"
    # The needles are 1280x800 screen coordinates, so set the resolution the
    # fixtures use instead of os-autoinst's 1024x768 default.
    #
    # STORAGE_KEEP_FREE_RATIO disables os-autoinst's pre-flight disk guard. It
    # wants 20% of the filesystem free plus a 50 GiB reserve before it creates
    # a 10 GiB disk, which a development host routinely does not have. CI skips
    # that check anyway.
    compose exec -T openqa "${cli[@]}" \
        SCENARIO_DEFINITIONS_YAML_FILE=/var/lib/openqa/share/tests/local-host/scenario-definitions.yaml \
        DISTRI=local-host VERSION=1 FLAVOR=live ARCH=x86_64 \
        "${test_setting[@]}" \
        CASEDIR=/var/lib/openqa/share/tests/local-host \
        NEEDLES_DIR=%%CASEDIR%%/needles \
        ISO="$ISO_NAME" \
        HDD_1=empty.qcow2 \
        "${suite_settings[@]}" \
        QEMURAM=4096 QEMUCPUS=2 \
        XRES=1280 YRES=800 \
        STORAGE_KEEP_FREE_RATIO=0
}

case "${1:-up}" in
    up)                       up ;;
    schedule)                 shift; schedule_run "$@" ;;
    schedule-suite)           shift; schedule_run --suite "$@" ;;
    schedule-data-drive)      shift; schedule_run --suite install-data-drive "$@" ;;
    schedule-backup-drive)    shift; schedule_run --suite install-backup-drive "$@" ;;
    schedule-backup-only)     shift; schedule_run --suite install-backup-only "$@" ;;
    schedule-webdav-backup)   shift; schedule_run --suite install-webdav-backup "$@" ;;
    schedule-data-backup-f2fs)
        shift; schedule_run --suite install-data-backup-f2fs "$@" ;;
    schedule-raid1)           shift; schedule_run --suite install-raid1 "$@" ;;
    schedule-raid0)           shift; schedule_run --suite install-raid0 "$@" ;;
    schedule-raid1-backup)
        shift; schedule_run --suite install-raid1-backup "$@" ;;
    schedule-raid1-backup-f2fs)
        shift; schedule_run --suite install-raid1-backup-f2fs "$@" ;;
    status)                   compose ps ;;
    logs)                     compose logs --follow ;;
    down)
        compose down
        printf 'container removed; volumes %s and %s kept\n' \
            "$DATA_VOLUME" "$PG_VOLUME"
        ;;
    purge)
        printf '==> Removing %s and deleting %s and %s\n' \
            "$NAME" "$DATA_VOLUME" "$PG_VOLUME"
        compose down -v
        ;;
    *)                        usage ;;
esac
