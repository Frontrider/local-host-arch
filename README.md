# Local-host image

This is a livecd for https://github.com/Frontrider/minimal-self-host. Will automatically start the compose stack on boot. 
If you don't fully understand what you're doing simply rebooting the computer will update the servers if anything is available. The host still needs to be update separately, a software manager is provided for that.

Built on top of manjaro for stability, with an i3 tiling desktop for lower overhead.
This image tries to be somewhat ergonomic (not fully!), while understanding that a fully fledged desktop is not needed for a server's deployment. Ideally you won't use more than the browser, and you'll only use it once a month at best.

Contains a falkon browser(low overhead), a file manager, a terminal emulator, a task manager (can be used for simple monitoring), and a NetworkManager applet for Wi-Fi.
The live session also includes GParted for preparing disks; it is not installed on the target system.

# Usage

Burn the image to a pendrive (we recommend rufus on windows, SUSE studio image writer for linux), boot from it then follow the installer.

On the live image the installer starts automatically as root. If you cancel it, the i3 bar **Installer** button or `Super+I` starts it again.

The i3 bar buttons also have `Super + first letter` bindings: `Super+M` menu,
`Super+I` installer, `Super+B` backups (opens the NPBackup GUI),
`Super+F` Falkon, `Super+T` terminal,
`Super+P` processes, `Super+L` lock, `Super+R` reboot and `Super+S` shutdown. The application menu and window
switcher use the Adapta-Nokto rofi theme.

The live ISO autologins; installed systems boot to the LightDM login screen.

On laptops, closing the lid stops LightDM and the X server; opening the lid starts them again. The live installer ignores lid events so an installation is not interrupted. This can give you a little more headroom when you don't use the gui.

After installation open the anywherelan control panel with the browser (a button is available on the bar for it), then pair your other devices. Do give it 2-5 minutes after boot because it has to download the docker images that run the core of the system, and it will also not work if the wifi is not available yet.
You have graphical tools to connect to any wifi if the computer can do that.

# Verification

The checks are pytest tests under `test/`. They run inside a disposable
Manjaro container, so the host only needs Docker.

One command runs the whole pipeline — cheap checks first, then the build, then
the checks that need the ISO:

```bash
./build-and-check.sh
```

Phases:

1. **No ISO needed** (`test/test_static.py`): `shellcheck`, `xmllint`,
   `desktop-file-validate`, `qmllint`, `qmlformat` on the profile.
2. **Build**: `./build.sh`.
3. **Needs the ISO** (`test/test_iso.py`): GRUB scripts, overlay files, a
   headless Calamares start, systemd units, and the branding shipped in the
   live filesystem. The phase 1 checks are not repeated.

The phases can also be run on their own:

```bash
bash test/run-docker.sh --static    # phase 1
bash test/run-docker.sh [image.iso] # phase 3, newest ISO by default
```

Each phase writes `out/reports/<phase>.html` and `out/reports/<phase>.xml`
(JUnit), including when a check fails.

Extra Python packages go in `test/requirements.txt`; the verification image is
rebuilt automatically when that file or the Dockerfile changes. A check whose
tool is missing is skipped with the reason instead of failing. See
`test/README.md` for details.

The release workflow runs the same suite in parallel: the no-ISO checks get
their own runner while the ISO builds, and the release job needs both, so a
release is never created while a check is failing.

The full install flow (boot the ISO, walk Calamares, boot the installed
system) is a separate local openQA check: `bash test/openqa.sh up`, then
`bash test/openqa.sh schedule`. `schedule` queues every suite: the default
install, a separate `/data` disk, a backup-only disk, `/data` plus backup,
f2fs backups, and RAID1/RAID0 data sets. Each one checks the installed
`/etc/fstab`. `schedule-suite NAME` runs only one of them. See
`test/README.md`.

The build itself already checks the overlays: `build.sh` runs
`test/check-overlay-files.sh` right after `buildiso` and stops when a template
file is missing from `rootfs.sfs`, `desktopfs.sfs` or `livefs.sfs`.


## AWL
The awl url of this device (local-host.awl by default) will get you to a simple application manager, that you can use to deploy what you need.
Every service is pre-configured to work out of the box with as few settings as possible. The awl domain is not available on the host, currently this is by design due to the internals of the tools that manage the deployments and the connectivity to the server.

Every service that we recommend using is marked as such.

## Device sharing
Some services work better if you are also connected to a friend. (XMPP chat) For that use, change the name of the service in awl, then have your devices match that name.

All of the shared services that require it are meant for small scale, personal use.

# Storage

`/data` is either a plain directory on the root filesystem or, if a data disk
was selected during installation, a separate filesystem mounted by fstab. The
compose stack binds its `localhost_data` volume under `/data`.

During the installer, you can chose to set up raid (use two drives to store the same data for redundancy) and/or automated backups.

On the data confirmation page, **Mount as-is** uses an existing btrfs, ext4,
f2fs or xfs filesystem without formatting or erasing it. It is available when
exactly one data drive remains after assigning an optional backup drive.

A selected disk can also be assigned as the backup drive while user data stays
on the system drive. The `/data` and backup filesystems are chosen
independently, so a btrfs data set with an f2fs backup disk is valid.

The system disk page also chooses the root filesystem: btrfs (default, with
the usual `/`, `/home`, `/var/cache` and `/var/log` subvolumes), ext4, f2fs or
xfs. btrfs is recommended because the image is built and tested around it.

### Backups

The main backup is a restic repository managed by
[NPBackup](https://github.com/netinvent/npbackup). NPBackup is a restic front
end, so the repository remains readable by plain `restic` if the tool is ever
removed.

The installer writes `/etc/local-host/npbackup.conf` only when a backup disk
was selected. The config is generated on the device and is not part of the
image git repository. It keeps the repository at `/backups/restic`, reads the
password from `/etc/local-host/restic-password`, and runs:

- a daily backup at midnight
- a weekly housekeeping run (quick check, retention policy, prune)

The desktop is administrator-only. The NPBackup GUI is available from the
i3 bar **Backups** button, with `Super+B`, or from the **Backup** application
entry. It also opens on the live image, where it has no repository configured
yet. The image ships a narrow sudoers rule for the root GUI wrapper; the
config, password and `/backups` stay root-only.

The backup disk is mounted on demand. The daily/weekly jobs mount it, run, and
unmount it again. The GUI leaves it mounted while it is open, so snapshots and
restores can be browsed; unmount it afterwards with:

```bash
sudo umount /backups
```

Store a copy of the /etc/local-host/restic-password file in a separate, safe location. Without it, you can not read the backups on a different machine! **You have been warned!**

### Second backup

The installer can also create a second, independent restic repository. It
only saves `/data/data/backed-up`, not the rest of `/data`, and it uses its
own password at `/etc/local-host/restic-secondary-password`. The folder must
exist before the first backup runs. The repository is stored either on the
backup drive (`/backups/restic-secondary`) or under
`/data/backup/restic-secondary`. The main backup excludes `/data/backup` so
the fallback repository is not copied into the main repository.

The second repository is also listed in `/etc/local-host/npbackup.conf`, so
the same NPBackup GUI can browse it, restore from it and run a manual backup.
The rclone mirror is still handled by the second-backup timer.

If a remote target is configured, rclone mirrors the repository after each
backup. The second backup page supports Google Drive, OneDrive, WebDAV and
FTP. For Google Drive and OneDrive, paste the token JSON produced by
`rclone authorize "drive"` or `rclone authorize "onedrive"` on another
computer. Its configuration lives in `/etc/local-host/secondary-backup.conf`
and `/etc/local-host/secondary-rclone.conf`; the daily and weekly jobs are
`local-host-backup-secondary.timer` and
`local-host-backup-secondary-housekeeping.timer`.

Store a copy of `/etc/local-host/restic-secondary-password` separately as
well. It is different from the main backup password. The NPBackup GUI only
manages the main backup; use restic to browse the second one. Mount
`/backups` first
(`sudo mount /backups`) if the drive is not mounted, then run:

```bash
sudo restic -r /backups/restic-secondary \
  --password-file /etc/local-host/restic-secondary-password snapshots
```

Use `/data/backup/restic-secondary` instead when no backup drive was
selected. Run the second backup immediately with:

```bash
sudo systemctl start local-host-backup-secondary.service
```


### F2FS

IF your only storage are pendrives, prefer backups over raid, because those can get used up and break out under the kind of load that this server can put on them. A backup mitigates that problem by having a second drive with less wear.
Avoid running video games and other software that write frequently. Writing is what can wear out the flash memory inside pendrives.

If you have a proper ssd/hdd and a pendrive, use the pendrive as the backup. The system runs midnight, then disconnects the backup drive to save up on its lifetime.

This file system was designed by Sony for the kind of flash memory taht is in their phones, then they released it to the public. SSDs, pendrives and sd cards are the same kind of memory so it can help making them last longer.


The AI crisis hit the market hard. This is not an ideal solution as pendrives were not made for this but it can still work if nothing else is available. **You should switch away from using them like this as soon as possible.**

# Notes

Nextcloud is a part of the application list, but I don't recommend using it for one reason. It does not like it when the storage it is attached to is written to by other services. It is also quite heavy.