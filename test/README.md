# Verification

The checks are pytest tests. They run inside the disposable Manjaro container
defined in `docker/Dockerfile`, so the host only needs Docker.

```
test/
  conftest.py            --iso option, ISO unpack fixture
  support.py             command runner, tool skip helper, paths
  test_static.py         checks that need no ISO
  test_iso.py            checks that need the ISO
  check-overlay-files.sh shared overlay comparison (also used by build.sh)
  requirements.txt       extra Python packages for the image
  docker/Dockerfile      the verification image
```

## Running

The whole pipeline — static checks, build, ISO checks — is one command at the
repository root:

```bash
./build-and-check.sh
```

The phases can also be run on their own:

```bash
bash test/run-docker.sh --static     # checks that need no ISO
bash test/run-docker.sh [image.iso]  # checks that need the ISO
```

## openQA

The full-install checks live in `test/openqa-distri/` and run in a local
openQA single-instance container:

```bash
bash test/openqa.sh up                # build and start, wait for the web UI
bash test/openqa.sh schedule [iso]    # every test suite, newest ISO by default
bash test/openqa.sh schedule-suite NAME [iso]
                                      # only one test suite
bash test/openqa.sh schedule-data-drive [iso]
                                      # install with a separate /data disk
bash test/openqa.sh schedule-backup-only [iso]
                                       # backup disk, data on the system disk
bash test/openqa.sh schedule-webdav-backup [iso]
                                       # restore from a WebDAV mirror
bash test/openqa.sh schedule-backup-drive [iso]
                                      # install with a data and backup disk
bash test/openqa.sh schedule-data-backup-f2fs [iso]
                                      # data and f2fs backup disks
bash test/openqa.sh schedule-raid1 [iso]
bash test/openqa.sh schedule-raid0 [iso]
                                      # two data disks in RAID1 or RAID0
bash test/openqa.sh schedule-raid1-backup [iso]
bash test/openqa.sh schedule-raid1-backup-f2fs [iso]
                                      # RAID1 data plus a backup disk
bash test/openqa.sh down              # stop, keep the database and results
```

The install suites are defined in
`test/openqa-distri/scenario-definitions.yaml` and `test/openqa-distri/main.pm`:

- `install` accepts the defaults: system and user data on the first disk.
- `install-data-drive` uses a second blank disk for `/data`.
- `install-backup-only` uses a second blank disk only as the backup drive;
  user data stays on the system drive.
- `install-webdav-backup` uses the same disk layout and configures a second
  restic backup on the backup drive with a WebDAV mirror.
- `install-backup-drive` uses one extra disk for `/data` and one as the
  backup disk.
- `install-data-backup-f2fs` is the same as `install-backup-drive` but the
  backup filesystem is f2fs.
- `install-raid1` and `install-raid0` put two data disks in the selected RAID
  level.
- `install-raid1-backup` and `install-raid1-backup-f2fs` put two data disks in
  RAID1 and add a backup disk (btrfs or f2fs).

Every extra-disk suite boots the installed system and reads `/etc/fstab`
through the serial console. It checks the mountpoints, filesystems, `nofail`
and `noauto` options, distinct UUIDs for separate drives, and for RAID1 the
`degraded` option that the installer adds to the `/data` entry. Both RAID
suites also check the mounted `/data` Btrfs profiles and device count.

`install-backup-only` also verifies the enabled midnight timer and uses a
temporary runtime override to trigger it after 20 seconds. It checks that
the service succeeded, released `/backups`, and saved a test file whose
contents can be read back from the restic snapshot.

`install-webdav-backup` runs the installed secondary backup service and
compares a file restored directly from the WebDAV snapshot while `/backups`
is unmounted. `up` starts the disposable WebDAV server alongside openQA. It
shares the worker's loopback (the QEMU guest reaches it at `10.0.2.2:8081`),
publishes no host port, and stores each job's repository in a separate
directory on temporary storage.

The shared install helper clicks the disk rows by position rather than
matching hardware-specific labels. The backup role and filesystem use stable
labels as anchors; the RAID0 row still uses an offset from the user-data
heading until a RAID screenshot is available. See
[`openqa-distri/needles/README.md`](openqa-distri/needles/README.md).

The web UI is at <http://localhost:1080>. `test/openqa-distri/` and
`out/manjaro/local-host/26.1.3/` (the current base Manjaro image) are
bind-mounted into the container, so no import step is needed. `schedule` also
hardlinks the selected build to openQA's product asset name
(`local-host-1-live.x86_64.iso`). `purge` deletes the data volumes.

## Reports

Each phase writes an HTML report and a JUnit XML report to `out/reports/`:

```
out/reports/static.html   out/reports/static.xml
out/reports/iso.html      out/reports/iso.xml
```

The HTML report is self-contained, so it can be opened or copied on its own.
The JUnit XML is what CI systems read. Both are written even when a check
fails.

## Adding Python packages

Add them to `test/requirements.txt` and run again. `run-docker.sh` hashes the
Dockerfile and `requirements.txt`, stores the hash on the image, and rebuilds
when it changes:

```bash
echo 'pytest-timeout' >> test/requirements.txt
bash test/run-docker.sh --static
```

The Dockerfile builds with `test/` as context, copies `requirements.txt` into
the image and runs `pip install -r` there. Nothing is installed on the host.

## What runs when

| Check | `test_static.py` | `test_iso.py` |
| --- | --- | --- |
| `shellcheck` on the profile's scripts | yes | |
| `xmllint` on `.ts`/`.xml` | profile | live branding |
| `desktop-file-validate` | yes | |
| `qmllint`, `qmlformat` on the pages | yes | |
| `osinfo-detect` | | yes |
| `grub-script-check` | | yes |
| overlay files byte-for-byte | | yes |
| `calamares -d -X` under `xvfb-run` | | yes |
| `systemd-analyze verify` / `cat-config` | | yes |

`test_static.py` is the fast gate: a broken script or QML page fails in
seconds, before the long build. `test_iso.py` does not repeat the static
checks.

## What each ISO check does

Tests run in file order, cheapest first, so a broken ISO fails on the fast
checks before the 30-second Calamares start.

The ISO is unpacked once per session: `boot/` for the GRUB scripts,
`manjaro/x86_64/livefs.sfs` for the live filesystem, and
`manjaro/x86_64/desktopfs.sfs` when the profile has a `desktop-overlay`.

- **Overlay files**: every file in `root-overlay`, `desktop-overlay` and
  `live-overlay` must exist byte-for-byte in its matching image
  (`rootfs.sfs`, `desktopfs.sfs`, `livefs.sfs`). `buildiso` copies overlays
  with `cp -LR`, so the comparison follows symlinks the same way. The same
  script runs at the end of `build.sh`, so a missing template file fails the
  build immediately.
- **GRUB**: every `boot/**/*.cfg` parses.
- **XML**: every `.ts`/`.xml` in the profile (static) and the live Calamares
  branding (ISO) parses.
- **Shell**: the shell scripts the profile installs (for example
  `desktop-overlay/usr/local/bin` and `live-overlay/usr/bin`) pass
  `shellcheck` at warning severity. The build and test tooling is not part of
  the application and is not checked. `SC1090`/`SC1091` are excluded because
  sourced files are outside the profile.
- **Desktop entries**: every `.desktop` in the profile validates.
- **Calamares**: the livefs configuration, pages and branding are layered over
  the container package, then `calamares -d -X` starts under `xvfb-run`. The
  check passes on a clean 30-second timeout and fails on a non-zero exit, on a
  missing `/etc/xdg/calamares/settings.conf`, or on fatal/module errors in the
  log.
- **QML**: `qmllint` and `qmlformat` run on every custom page. `qmllint`
  reports the C++-registered `io.calamares.core` import as a warning, so only
  `Error:` output fails the check.
- **systemd**: every unit in the ISO's `/etc/systemd/system` passes
  `systemd-analyze verify` against the extracted live filesystem, and
  `systemd-analyze cat-config` reads `system.conf` and `logind.conf`.

## Skipping

Every tool is installed best-effort. A test whose tool is missing is reported
as `SKIPPED` with the reason (`pytest -rs` lists them), so a missing package
never hides the checks that can run.

## Notes

- The extracted live filesystem needs a few GB of space in the container.
- The repository and the ISO are mounted read-only; pytest writes nothing
  there.
- The GitHub workflow runs `run-docker.sh --static` in a job that runs in
  parallel with the build, then the ISO checks in the build job, and only
  publishes when both jobs pass.
