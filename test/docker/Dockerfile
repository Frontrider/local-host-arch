# Verification image for the local-host Manjaro ISO.
#
# Manjaro is used instead of Arch because Calamares and its Manjaro branding
# live in the Manjaro repositories; Arch does not package Calamares at all.
#
# Every optional package is installed best-effort. When a tool is missing the
# matching pytest check reports a skip instead of failing the whole build.
#
# Build with test/ as the context, so requirements.txt can be copied in:
#   docker build -f test/docker/Dockerfile -t local-host-verify test
FROM manjarolinux/base:latest

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN set -eux; \
    pacman -Syu --noconfirm --needed \
        bash coreutils diffutils findutils gawk grep sed which \
        libarchive squashfs-tools libisoburn util-linux \
        libosinfo osinfo-db \
        grub libxml2 shellcheck desktop-file-utils \
        qt6-declarative systemd dbus \
        xorg-server-xvfb xorg-xauth \
        python python-pip \
    || { \
        pacman-key --init; \
        pacman-key --populate manjaro archlinux; \
        pacman -Syu --noconfirm --needed \
            bash coreutils diffutils findutils gawk grep sed which \
            libarchive squashfs-tools libisoburn util-linux \
            libosinfo osinfo-db \
            grub libxml2 shellcheck desktop-file-utils \
            qt6-declarative systemd dbus \
            xorg-server-xvfb xorg-xauth \
            python python-pip; \
    }; \
    pacman -Scc --noconfirm


# Optional: the installer framework itself, needed to load the ISO
# configuration headlessly.
RUN pacman -S --noconfirm --needed calamares \
    || echo 'WARN: calamares is unavailable, the configuration load check will skip'

# Qt installs qmllint and qmlformat outside /usr/bin on some layouts. Put them
# into PATH when present so they can be called by name.
RUN set -eux; \
    for tool in qmllint qmlformat; do \
        if ! command -v "$tool" >/dev/null 2>&1; then \
            found="$(find /usr/lib/qt6 /usr/libexec -type f -name "$tool" -perm -u+x 2>/dev/null | head -n 1)"; \
            if [ -n "$found" ]; then ln -sf "$found" "/usr/bin/$tool"; fi; \
        fi; \
        command -v "$tool" >/dev/null 2>&1 \
            || echo "WARN: $tool is unavailable, the QML check will skip"; \
    done

# Python packages for the checks, installed inside this image only. Add
# anything you need to test/requirements.txt; test/run-docker.sh rebuilds the
# image when that file changes.
COPY requirements.txt /tmp/requirements.txt
RUN set -eux; \
    python3 -m pip install --no-cache-dir --break-system-packages \
        -r /tmp/requirements.txt; \
    rm -f /tmp/requirements.txt

WORKDIR /repo
