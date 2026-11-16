# local-host-arch

A small, self-contained Manjaro live ISO build using **manjaro-tools**
(`buildiso`), plus a QEMU launcher for testing it.

The ISO is a small i3 desktop live system: rofi launcher, Falkon browser,
Docker/Compose, and a clickable Falkon button in the i3 bar. There is no
Calamares installer; it is meant as a reproducible base you can extend.

```
.
├── .gitlab-ci.yml                # GitLab CI: build + release
├── .github/workflows/publish-iso.yml  # GitHub Actions: build + release
├── build.sh                      # runs buildiso, elevates with sudo
├── run-vm.sh                     # boots the resulting ISO in QEMU
├── iso-profiles/
│   ├── repo_info                 # marks this as a valid iso-profiles repo
│   └── manjaro/local-host/
│       ├── profile.conf          # live-session settings
│       ├── Packages-Root         # rootfs.sfs packages
│       ├── Packages-Desktop      # desktopfs.sfs packages (i3, rofi, ...)
│       ├── Packages-Live         # livefs.sfs packages
│       ├── desktop-overlay/      # files copied into desktopfs.sfs
│       └── live-overlay/         # files copied into livefs.sfs
├── out/                          # built ISOs        (created, gitignored)
└── work/                         # chroots, logs, VM vars (created, gitignored)
```

Everything manjaro-tools needs is kept inside this directory: `build.sh`
runs `buildiso` with `HOME=work/home`, so its configuration lives in
`work/home/.config/manjaro-tools/` and is never written to `~/.config`.

## Requirements

The setup targets these Arch/Manjaro packages (all already present on this
host):

| Package | Provides |
| --- | --- |
| `manjaro-tools-iso-git` | `buildiso`, initcpio hooks |
| `manjaro-tools-base-git` | `mkchroot`, chroot helpers |
| `manjaro-tools-yaml-git` | Calamares/YAML helpers sourced by `buildiso` |
| `manjaro-iso-profiles-base` | `shared/` lists (pulled as a dependency) |
| `libisoburn` | `xorriso` (ISO mastering) |
| `mktorrent` | torrent metadata for the ISO |
| `calamares-tools`, `ruby-kwalify` | config validation helpers |
| `qemu-base` | `qemu-system-x86_64`, `qemu-img` |
| `edk2-ovmf` | UEFI firmware for the VM |

Packages are **not installed by these scripts**. To check the current host:

```sh
./build.sh --check
```

Install the set explicitly if it is ever missing (not needed right now):

```sh
sudo pacman -S --needed manjaro-tools-iso-git libisoburn mktorrent \
    calamares-tools ruby-kwalify qemu-base edk2-ovmf
```

Optional (never required): `qemu-desktop` adds the GTK/SDL display backends
for a native QEMU window. With only `qemu-base`, `run-vm.sh` uses VNC
automatically. Even when `qemu-desktop` is installed, `--display vnc` still
forces the VNC backend.

### Status on this host

* Build toolchain: complete — nothing to install.
* Perl, xorriso, mktorrent, kwalify, grub tools, dosfstools, squashfs-tools: present.
* `qemu-base` and `edk2-ovmf` (required for the VM): present.
* `qemu-desktop` (optional native window): installed, but not required.


## Build

```sh
./build.sh              # sudo password prompt; downloads packages into work/
```

The first build needs network access and roughly 8-10 GiB of free space
(rootfs, desktopfs and livefs chroots plus the compressed images). Artefacts:

```
out/manjaro/local-host/<host release>/manjaro-local-host-<release>-minimal-<date>-<kernel>.iso
```

Useful options:

```sh
./build.sh --check                # verify tools + that every profile package exists
./build.sh --clean                # delete out/ and work/
./build.sh -k linux612            # use another kernel (default: linux618)
./build.sh -c                     # incremental; keep existing chroots
./build.sh -x                     # build squashfs images only
./build.sh -z                     # repack an ISO from existing images
./build.sh --mirror URL           # use a specific mirror root
./build.sh --retries 5            # more automatic downloads retries
./build.sh --help
```

The ISO is built from `https://mirrors.manjaro.org/repo` (Manjaro's
mirror redirector) by default, not from a single hard-coded mirror.
Package downloads are retried automatically: if `buildiso` fails with a
download error, the build is resumed with `-c` up to `--retries` times
(default 3). Logs are kept in `work/logs/`.

If a build stops for any other reason, fix the cause and continue with:

```sh
./build.sh --resume               # same as -c; reuses rootfs/desktopfs/livefs
```

`buildiso`'s own default kernel is `linux66`, which is no longer in the
current repositories, so `build.sh` defaults to `linux618`.

## GitLab CI: build and release

`.gitlab-ci.yml` builds the ISO inside a privileged `manjarolinux/base`
container and publishes it as a GitLab Release asset:

- A tag pipeline with a URL-safe tag (e.g. `v1.0.0`) builds the ISO, uploads
  the ISO and `SHA256SUMS` to the project's **Generic Package Registry**, and
  creates a GitLab **Release** linking both files.
- Ordinary branch pipelines expose a **manual** `build-iso` job. It uploads
  the image with a `<branch>-<commit>` package version; no release is created.
- The ISO is deliberately not a job artifact (it exceeds the default artifact
  size limit). Download it from **Releases → Assets** or **Packages**.

Runner requirements:

- a runner tagged `iso-builder` (or set `ISO_RUNNER_TAG`),
- Docker executor with `privileged = true` (buildiso creates and mounts
  chroots), or a shell runner on a Manjaro host with root/sudo,
- at least 15 GiB free disk and access to the Manjaro mirrors.

GitLab.com shared runners cannot run this because privileged containers are
disabled. Register a project/group runner, for example:

```toml
[[runners]]
  name = "iso-builder"
  executor = "docker"
  [runners.docker]
    image = "manjarolinux/base:latest"
    privileged = true
```

Other variables: `ISO_BUILD_IMAGE`, `KERNEL` (default `linux618`),
`BUILD_MIRROR`. The Generic Package Registry must be enabled.

```sh
git tag v1.0.0
git push origin v1.0.0
```

## GitHub Actions: build and release

`.github/workflows/publish-iso.yml` builds the ISO on a GitHub-hosted Ubuntu
runner inside a privileged `manjarolinux/base` container (the Manjaro build
tools, xorriso, squashfs-tools, grub and friends are installed there) and
runs `./build.sh --no-check`.

- Every run uploads the ISO and `SHA256SUMS` as a workflow artifact.
- Pushing a regular semantic version tag such as `v1.2.3` creates/updates a
  GitHub Release with the same files.
- A manual **Run workflow** builds an artifact; set the optional `tag` input
  to a `vMAJOR.MINOR.PATCH` value to publish a release as well.

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow only runs on semantic version tags (`vX.Y.Z`) and manual
dispatch, not on ordinary pushes. Manual tags must match
`vMAJOR.MINOR.PATCH`; the job validates this before building.
It frees runner disk space first (the chroots plus the ISO need roughly
12 GiB). The ISO is currently ~1.7 GiB, below GitHub's 2 GiB per-release
asset limit. Actions must be enabled, and the workflow declares
`contents: write` for releases.

## Run in a VM

```sh
./run-vm.sh                       # live ISO + default work/vm/disk.qcow2
./run-vm.sh --no-disk             # live ISO without a disk
./run-vm.sh --boot installed      # boot the installed system from the disk
./run-vm.sh --bios                # legacy SeaBIOS boot
./run-vm.sh --disk other.qcow2    # custom install disk
./run-vm.sh -m 8192 -c 8
```

A 25 GiB sparse qcow2 disk (`work/vm/disk.qcow2`) is attached by default so
the live session can install to it; `--no-disk` restores the diskless case.

The live session boots to **LightDM's login screen** (autologin is disabled).
Log in as `manjaro` / `manjaro`; the `i3` session is selected automatically.
A `live-machine-id` oneshot service initializes `/etc/machine-id` before
systemd-firstboot, so there is no console `Initial Setup` wizard. A console
login is also available on tty2 with
<kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F2</kbd>.

### Desktop

| Action | How |
| --- | --- |
| Application menu | click **Menu** in the bar, or <kbd>Super</kbd>+<kbd>d</kbd> (rofi, searchable) |
| Window switcher | <kbd>Super</kbd>+<kbd>Tab</kbd> (rofi) |
| Terminal | <kbd>Super</kbd>+<kbd>Return</kbd> (xfce4-terminal; `xterm` is also installed) |
| Falkon on `http://localhost:8080`(awl admin) | click the green **Falkon: admin.awl** block in the top bar, or <kbd>Super</kbd>+<kbd>b</kbd> |
| Workspaces / move windows | <kbd>Super</kbd>+<kbd>1..0</kbd> / +<kbd>Shift</kbd> |
| Close window | middle-click its titlebar, click **Close** in the bar, or <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>q</kbd> |
| Lock screen | <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>l</kbd>, click **Lock** in the bar, or 10 minutes idle; unlock with the `manjaro` password |
| Exit i3 | <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>e</kbd> |

File manager: Thunar (`thunar`); text editor: Mousepad (`mousepad`). Both
appear in the **Menu** and can be started from a terminal as well.

Window title bars are enabled (`default_border normal`). i3 does not draw
titlebar buttons, so a middle-click on a title bar closes the window; the red
**Close** block in the bar closes the focused window as well.

The bar is i3bar (rofi is the launcher, not a bar). Its clickable Falkon
block is produced by `/usr/local/bin/i3bar-falkon-status`, which handles
i3bar click events itself. The URL is `http://admin.awl`; override it with
`FALKON_URL` in the script or edit the i3 config.

Docker is enabled and the live user is in the `docker` group, so
`docker ps` and `docker compose version` work without sudo. The live
filesystem is itself an overlay, so `/etc/docker/daemon.json` selects the
`vfs` storage driver; image pulls are slower and consume RAM (the live
root is a tmpfs).

If a click on the bar button does not open the browser, the launch log is
`/tmp/falkon-launch.log` inside the live session. <kbd>Super</kbd>+<kbd>b</kbd>
runs exactly the same command. The status command must advertise
`"click_events": true` in its i3bar header, otherwise i3bar never forwards
clicks to it.

### Manjaro update tray

Update notifications are shown exactly the way Manjaro shows them: pamac's
own tray icon. `pamac-gtk3` provides `pamac-tray`, which registers a
GtkStatusIcon (XEmbed) with the system tray. i3bar has a built-in XEmbed
tray (`tray_output primary`), so the icon appears on the right side of the
bar. It shows the normal update/no-update icon — kernel updates are ordinary
`linuxNNN` package updates and are included — and clicking it opens
`pamac-manager`. A `polkit-gnome` authentication agent is started by i3 so
installing from `pamac-manager` can authenticate.

There is deliberately no textual update block in the bar. If a future pamac
switches from GtkStatusIcon to StatusNotifierItem, `snixembed` (available in
the repos) can proxy it into the same XEmbed tray.

### Manjaro Hello and installing

`manjaro-hello` is installed and started by i3 if its autostart entry exists.
On the live ISO it sees `/run/miso/bootmnt/manjaro`, so it shows its
**Install** button. That button runs `calamares_polkit` (provided by the
`calamares` package, which is in `Packages-Live`).

Calamares is generated/configured by manjaro-tools and unpacks both
`rootfs.sfs` and `desktopfs.sfs`, so an installed system keeps the same i3
desktop (rofi, Falkon, Docker, pamac tray). The live polkit rule written by
`buildiso` lets the live user start the installer without a password;
`polkit-gnome` is also running as the authentication agent.

To try an install, just boot the ISO — the default disk is already attached:

```sh
./run-vm.sh
```

Then use **Install** in Manjaro Hello and select `/dev/vda` (the 25 GiB
disk). When Calamares finishes, shut the VM down and boot the installed
system from the same disk:

```sh
./run-vm.sh --boot installed
```

### local-host Compose stack

`/etc/local-host` is shipped from
`iso-profiles/manjaro/local-host/desktop-overlay/etc/local-host/`
(`docker-compose.yaml`, `env`, and the `rootfs/` file bind-mounted by the
`app-manager` service).

`local-host-compose.service` is enabled in the live image. It:

* loads the `tun` module (`/etc/modules-load.d/tun.conf`) for Tailscale,
* waits until `dockerd` answers,
* runs `docker compose --env-file env -f docker-compose.yaml up -d` from
  `/etc/local-host`,
* repeats that every 30 seconds, so stopped/removed containers come back,
* is restarted by systemd (`Restart=always`) if the loop ever dies.

The containers' own `restart:` policies still handle crashes between
iterations. The first boot has to pull the `ghcr.io/frontrider/*` images, so
give the VM network access and preferably 8 GiB RAM; Docker uses the `vfs`
storage driver on the live overlay.

Docker and the compose unit deliberately do **not** wait for
`network-online.target`: on this image that target could hang on
`systemd-networkd-wait-online.service` even though NetworkManager manages
the network. A drop-in disables the networkd wait unless systemd-networkd is
actually running, and a docker drop-in removes the `network-online.target`
ordering. The supervisor retries pulls until networking is ready.

Set `LOCALHOST_TS_AUTH_KEY` (and `LOCALHOST_MAIL`) in the `env` file before
building if the stack needs them. Logs: `journalctl -u local-host-compose`
or `docker compose -f /etc/local-host/docker-compose.yaml logs`.

Notes:

* UEFI uses `OVMF_CODE.4m.fd` plus a writable variable store at
  `work/vm/OVMF_VARS.fd`. Delete that file to reset the firmware settings.
* Default networking is QEMU user-mode (`virtio-net`, DHCP via NetworkManager).
* The GTK/SDL backends are optional. With only `qemu-base` installed the
  script starts VNC on `127.0.0.1:5900` and prints the connection command.
  `--display vnc` forces VNC regardless of what is installed; `--display
  none` runs fully headless. This host currently also has `qemu-desktop`,
  so the default `auto` picks GTK when `DISPLAY` is set.
* Falkon (QtWebEngine) and Docker are more comfortable with 8 GiB:
  `./run-vm.sh -m 8192`.
* Shut the guest down with `sudo poweroff` (or QEMU's monitor via
  <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>2</kbd>, then `quit`).

## Customising the ISO

* `iso-profiles/manjaro/local-host/Packages-Root` — base system in
  `rootfs.sfs`. `KERNEL` is replaced with the `-k` value.
* `iso-profiles/manjaro/local-host/Packages-Desktop` — desktop packages in
  `desktopfs.sfs` (i3, rofi, Falkon, Docker, LightDM).
* `iso-profiles/manjaro/local-host/Packages-Live` — packages added for
  `livefs.sfs`.
* `iso-profiles/manjaro/local-host/profile.conf` — hostname, live user,
  services, display manager, boot loader, and so on.
* `iso-profiles/manjaro/local-host/desktop-overlay/etc/skel/.config/i3/config`
  — i3 keybindings and bar configuration.
* `iso-profiles/manjaro/local-host/desktop-overlay/usr/local/bin/i3bar-falkon-status`
  — i3bar status command with the clickable Falkon button.
* `iso-profiles/manjaro/local-host/desktop-overlay/etc/local-host/` — the
  Compose stack, its env file and the bind-mounted app-manager entrypoint.
* `iso-profiles/manjaro/local-host/live-overlay/usr/local/bin/local-host-compose`
  and `live-overlay/etc/systemd/system/local-host-compose.service` — the
  always-on Compose supervisor.

The i3 config and bar script are installed into `/etc/skel`, so they are
copied to the live user's home when `manjaro-live-setup` creates it.
Add `calamares` to `Packages-Live` if you also want the installer.
