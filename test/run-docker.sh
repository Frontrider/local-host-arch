#!/usr/bin/env bash
# Run the pytest suite in a disposable Manjaro container. The host only needs
# Docker.
#
#     bash test/run-docker.sh --static      # checks that need no ISO
#     bash test/run-docker.sh [image.iso]   # checks that need the ISO
#
# Reports are written to out/reports/: <phase>.html and <phase>.xml (JUnit).
# A check whose tool is missing is reported as skipped, with the reason.
# Set VERIFY_REBUILD=1 to force a rebuild of the helper image.

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd -P)
IMAGE="${VERIFY_IMAGE:-local-host-verify:latest}"
REPORTS_DIR="$REPO_ROOT/out/reports"

MODE=iso
case "${1:-}" in
    --static)
        MODE=static
        shift
        ;;
    --iso-only)
        shift
        ;;
esac
ISO="${1:-${ISO:-}}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required"

# Rebuild the image whenever the Dockerfile or requirements.txt changes, so a
# new package is installed without asking the user to remember a flag.
stamp=$(cat "$TEST_DIR/docker/Dockerfile" "$TEST_DIR/requirements.txt" \
    | sha256sum | cut -d' ' -f1)
have=$(docker image inspect --format \
    '{{ index .Config.Labels "org.local-host.verify" }}' "$IMAGE" 2>/dev/null) \
    || have=""

if [[ ${VERIFY_REBUILD:-0} == 1 || $have != "$stamp" ]]; then
    printf '==> Building verification image %s\n' "$IMAGE"
    docker build --pull -f "$TEST_DIR/docker/Dockerfile" -t "$IMAGE" \
        --label "org.local-host.verify=$stamp" "$TEST_DIR"
fi

mkdir -p "$REPORTS_DIR"

pytest_args=(-v -rs -p no:cacheprovider)
docker_args=(
    --rm --init --shm-size=1g
    -e HOME=/root
    -e PYTHONDONTWRITEBYTECODE=1
    -v "$REPO_ROOT:/repo:ro"
    -v "$REPORTS_DIR:/reports"
)

reports() {
    local ext
    for ext in html xml; do
        if [[ -f $REPORTS_DIR/$1.$ext ]]; then
            printf '    %s: %s\n' "$ext" "$REPORTS_DIR/$1.$ext"
        fi
    done
}

if [[ $MODE == static ]]; then
    printf '==> Running the checks that need no ISO\n'
    set +e
    docker run "${docker_args[@]}" "$IMAGE" \
        python3 -m pytest "${pytest_args[@]}" \
        --html=/reports/static.html --self-contained-html \
        --junitxml=/reports/static.xml \
        test/test_static.py
    rc=$?
    set -e
    reports static
    ((rc == 0)) || printf 'ERROR: container exited with status %d\n' "$rc" >&2
    exit "$rc"
fi

if [[ -z $ISO ]]; then
    ISO=$(find "$REPO_ROOT/out" -type f -name '*.iso' -printf '%T@ %p\n' \
        | sort -n | tail -n 1 | cut -d' ' -f2-)
fi
[[ -n $ISO ]] || die "no ISO found under $REPO_ROOT/out"
[[ -f $ISO ]] || die "ISO not found: $ISO"
ISO=$(cd -- "$(dirname -- "$ISO")" && pwd -P)/$(basename -- "$ISO")

printf '==> Running the checks that need the ISO\n'
set +e
docker run "${docker_args[@]}" \
    -e ISO=/iso.iso \
    -v "$ISO:/iso.iso:ro" \
    "$IMAGE" \
    python3 -m pytest "${pytest_args[@]}" \
    --html=/reports/iso.html --self-contained-html \
    --junitxml=/reports/iso.xml \
    test/test_iso.py
rc=$?
set -e
reports iso
((rc == 0)) || printf 'ERROR: container exited with status %d\n' "$rc" >&2
exit "$rc"
