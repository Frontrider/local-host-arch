#!/usr/bin/env python3
"""Partition and format the installation disk with FAI setup-storage.

The disk, root filesystem and swap choice are collected before the Summary
page. This job runs only after Summary has been accepted, so nothing is
written while the user is still navigating.

FAI's setup-storage creates the GPT/msdos layout and the ESP and swap
filesystems. The root filesystem is btrfs, ext4, f2fs or xfs, as chosen on the
disk page. The btrfs root is formatted here (rather than by FAI) because
Calamares' mount module creates the @, @home, @cache and @log subvolumes
itself; letting FAI pre-create @ would make that step fail. The other root
filesystems are created by FAI directly.

The data and backup devices selected on the data pages are formatted in this
same job. That folds the old data-format step into setup-storage and keeps the
data layout out of Calamares' system partition map, so mount/fstab only see
the system disk. data-fstab later adds /data and /backups to the target fstab.

Global Storage produced for the rest of Calamares:
  partitions          ESP/root/swap map (mount, fstab, bootloader)
  firmwareType        efi or bios
  efiSystemPartition  /boot/efi
  bootLoader          {"installPath": <install disk>}
  partitionChoices    {"install": "erase", "swap": <choice>}
  dataFormatted       data/backup entries for data-fstab
"""

import json
import os
import re
import shutil
import subprocess
import tempfile

import libcalamares


EFI_SYSTEM_PARTITION = "/boot/efi"
ROOT_LABEL = "ROOT"
DATA_LABEL = "DATA"
BACKUP_LABEL = "BACKUPS"
NETWORK_PREFIXES = ("/dev/nbd", "/dev/rbd", "/dev/drbd")
LIVE_MOUNTS = ("/run/miso", "/run/archiso", "/run/ventoy")


class StorageError(Exception):
    pass


class SecondaryBackupError(StorageError):
    pass


def pretty_name():
    return "Partitioning and formatting with setup-storage"


def _run(args, check=False):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
    if check and result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "command failed"
        raise StorageError("{}: {}".format(" ".join(args), message))
    return result


def _global(key):
    value = libcalamares.globalstorage.value(key)
    return "" if value is None else str(value)


def _check_secondary_backup():
    """Validate the second-backup page before any disk is touched."""
    enabled = _global("secondaryBackupEnabled").strip().lower() in (
        "true", "1", "yes")
    if not enabled:
        return

    location = _global("secondaryBackupLocation").strip().lower() or "data"
    if location not in ("drive", "data"):
        raise SecondaryBackupError(
            "Unsupported location '{}'.".format(location))
    if location == "drive" and not _global("dataPlanBackup").strip():
        raise SecondaryBackupError(
            "No backup drive was selected on the storage pages.")

    provider = _global("secondaryBackupProvider").strip().lower() or "none"
    if provider not in ("none", "drive", "onedrive", "webdav", "ftp"):
        raise SecondaryBackupError(
            "Unsupported remote '{}'.".format(provider))

    if provider in ("drive", "onedrive"):
        label = "Google Drive" if provider == "drive" else "OneDrive"
        key = ("secondaryBackupGoogleToken" if provider == "drive"
               else "secondaryBackupOneDriveToken")
        token = " ".join(_global(key).split())
        if not token:
            raise SecondaryBackupError(
                "A {} token is required.".format(label))
        try:
            parsed = json.loads(token)
        except ValueError as error:
            raise SecondaryBackupError(
                "The {} token is not valid JSON: {}".format(label, error))
        if not isinstance(parsed, dict):
            raise SecondaryBackupError(
                "The {} token must be a JSON object.".format(label))
    elif provider == "webdav":
        if not _global("secondaryBackupWebdavUrl").strip():
            raise SecondaryBackupError(
                "A WebDAV URL is required.")
    elif provider == "ftp":
        if not _global("secondaryBackupFtpHost").strip():
            raise SecondaryBackupError("An FTP host is required.")
        port = _global("secondaryBackupFtpPort").strip() or "21"
        if not port.isdigit():
            raise SecondaryBackupError(
                "The FTP port must be a number: {}".format(port))


def _is_block(device):
    try:
        return os.path.exists(device) and os.stat(device).st_mode & 0o060000 == 0o060000
    except OSError:
        return False


def _is_whole_disk(device):
    result = _run(["lsblk", "-dno", "TYPE", device])
    return result.returncode == 0 and result.stdout.strip() == "disk"


def _parent_disk(device):
    result = _run(["lsblk", "-no", "PKNAME", "-p", device])
    if result.returncode != 0:
        return ""
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return lines[0] if lines else ""


def _mount_info(device):
    result = _run(["lsblk", "-ln", "-p", "-o", "NAME,MOUNTPOINT", device])
    rows = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 1)
        if not fields:
            continue
        rows.append((fields[0], fields[1].strip() if len(fields) > 1 else ""))
    return rows


def _unmount_disk(disk):
    """Release anything on the target disk before setup-storage wipes it."""
    # Children are listed after their parents; unmount deepest first.
    for device, mountpoint in reversed(_mount_info(disk)):
        if not mountpoint:
            continue
        if mountpoint == "[SWAP]":
            _run(["swapoff", device], check=True)
            continue
        if mountpoint.startswith(LIVE_MOUNTS):
            raise StorageError(
                "Refusing to install on {}: it is the live medium at {}".format(
                    disk, mountpoint))
        libcalamares.utils.debug(
            "Unmounting {} from {} before partitioning".format(device, mountpoint))
        result = _run(["umount", "-R", mountpoint])
        if result.returncode != 0 and "not mounted" not in result.stderr.lower():
            raise StorageError(
                "Cannot unmount {} from {}: {}".format(
                    device, mountpoint, result.stderr.strip()))


def _uuid(device):
    result = _run(["blkid", "-s", "UUID", "-o", "value", device])
    lines = result.stdout.strip().splitlines()
    return lines[0].strip() if lines else ""


def _fstype(device):
    result = _run(["blkid", "-s", "TYPE", "-o", "value", device])
    lines = result.stdout.strip().splitlines()
    return lines[0].strip() if lines else ""


def _partuuid(device):
    result = _run(["blkid", "-s", "PARTUUID", "-o", "value", device])
    lines = result.stdout.strip().splitlines()
    return lines[0].strip() if lines else ""


def _partlabel(device):
    result = _run(["lsblk", "-dno", "PARTLABEL", device])
    return result.stdout.strip()


def _wipe(device):
    _run(["wipefs", "-a", "-f", device], check=True)
    result = _run(["blockdev", "--getsz", device])
    sectors = int(result.stdout.strip() or "0") if result.stdout.strip() else 0
    _run(["dd", "if=/dev/zero", "of=" + device, "bs=512", "count=2048",
          "conv=notrunc", "status=none"], check=True)
    if sectors > 4096:
        _run(["dd", "if=/dev/zero", "of=" + device, "bs=512", "count=2048",
              "seek={}".format(sectors - 2048), "conv=notrunc",
              "status=none"], check=True)


def _partition_path(disk, number):
    """Match FAI/parted's partition naming for nvme, mmc and loop disks."""
    if re.match(r"^/dev/(nvme\d+n\d+|mmcblk\d+|loop\d+|md\d+)$", disk):
        return "{}p{}".format(disk, number)
    return "{}{}".format(disk, number)


def _meminfo_mib():
    try:
        with open("/proc/meminfo", encoding="ascii") as meminfo:
            for line in meminfo:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return 0


def _disk_mib(disk):
    result = _run(["lsblk", "-bdno", "SIZE", disk])
    try:
        return int(result.stdout.strip()) // (1024 * 1024)
    except ValueError:
        return 0


def _swap_mib(choice, disk):
    """Mirror Calamares' small/suspend suggestion so the sizes are familiar."""
    ram = _meminfo_mib()
    if ram <= 0:
        ram = 2048
    if ram <= 4096:
        suggested = ram * 2
    elif ram <= 8192:
        suggested = 8192
    else:
        suggested = ram
    if choice == "suspend":
        suggested = int(round(suggested * 1.1))
    else:
        suggested = min(8192, suggested)
        suggested = int(round(suggested * 1.1))
        suggested = min(suggested, max(512, _disk_mib(disk) // 10))
    return max(512, suggested)


def _is_efi():
    return os.path.isdir("/sys/firmware/efi")


def _layout(disk, swap_choice, root_fs):
    """Return ordered partition entries. The first partition is bootable."""
    efi = _is_efi()
    disk_mib = _disk_mib(disk)
    swap_mib = 0 if swap_choice == "none" else _swap_mib(swap_choice, disk)
    required = (512 if efi else 0) + swap_mib + 4096
    if disk_mib and required > disk_mib:
        raise StorageError(
            "{} is too small for the selected swap choice: {} MiB needed, "
            "{} MiB available.".format(disk, required, disk_mib))

    entries = []
    if efi:
        entries.append({
            "role": "efi",
            "mount": EFI_SYSTEM_PARTITION,
            "fai_mount": EFI_SYSTEM_PARTITION,
            "fai_fs": "vfat",
            "fs": "fat32",
            "size": "512",
            "fai_type": "p=EFI",
            "options": "rw",
            "bootable": True,
        })
    if swap_choice != "none" and not efi:
        # On BIOS the bootable partition is the root partition, so put swap
        # first. Then root can use 100% of the remaining space.
        entries.append({
            "role": "swap",
            "mount": "",
            "fai_mount": "swap",
            "fai_fs": "swap",
            "fs": "linuxswap",
            "size": str(swap_mib),
            "fai_type": "primary",
            "options": "sw",
        })
    if swap_choice != "none" and efi:
        entries.append({
            "role": "swap",
            "mount": "",
            "fai_mount": "swap",
            "fai_fs": "swap",
            "fs": "linuxswap",
            "size": str(swap_mib),
            "fai_type": "p=SWAP",
            "options": "sw",
        })
    entries.append({
        "role": "root",
        "mount": "/",
        "fai_mount": "/",
        # FAI must not format btrfs here: mount creates the subvolumes.
        # Other filesystems are created by FAI directly.
        "fai_fs": "-" if root_fs == "btrfs" else root_fs,
        # A reinstall may leave an old filesystem signature on the new
        # partition. mkfs refuses that without its force option; FAI only
        # adds -f for xfs itself.
        "fai_createopts": {
            "ext4": "-F",
            "f2fs": "-f",
            "xfs": "-f",
        }.get(root_fs, ""),
        "fs": root_fs,
        # FAI treats 100% as a fixed partition of the whole disk size, so a
        # root partition after the ESP/swap overflows. 0-100% is a range that
        # FAI scales down to the space left after the earlier partitions.
        "size": "0-100%",
        "fai_type": "p=ROOT" if efi else "primary",
        "options": "rw",
        "bootable": not efi,
    })
    for index, entry in enumerate(entries):
        entry["number"] = index + 1
        entry["device"] = _partition_path(disk, index + 1)
    return entries


def _fai_config(disk, entries):
    label = "gpt" if _is_efi() else "msdos"
    bootable = next(
        (entry["number"] for entry in entries if entry.get("bootable")), 1)
    lines = [
        "# Generated by local-host-setup-storage. Do not edit.",
        "disk_config {} disklabel:{} fstabkey:uuid bootable:{} align-at:1M".format(
            disk, label, bootable),
    ]
    for entry in entries:
        line = "{} {} {} {} {}".format(
            entry["fai_type"], entry["fai_mount"], entry["size"],
            entry["fai_fs"], entry["options"])
        if entry.get("fai_createopts"):
            line += ' createopts="{}"'.format(entry["fai_createopts"])
        lines.append(line)
    return "\n".join(lines) + "\n"


def _setup_storage_binary():
    for candidate in ("/usr/bin/setup-storage", "/usr/sbin/setup-storage",
                      "/usr/local/sbin/setup-storage"):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which("setup-storage")
    if found:
        return found
    raise StorageError("setup-storage is not installed in the live image.")


def _settle():
    _run(["udevadm", "settle", "--timeout=30"])


def _run_fai(disk, entries):
    workdir = tempfile.mkdtemp(prefix="local-host-setup-storage-")
    config = os.path.join(workdir, "disk_config")
    logdir = os.path.join(workdir, "log")
    os.makedirs(logdir, exist_ok=True)
    contents = _fai_config(disk, entries)
    with open(config, "w", encoding="utf-8") as output:
        output.write(contents)
    libcalamares.utils.debug("FAI disk config:\n" + contents)

    command = [_setup_storage_binary(), "-X", "-f", config,
               "-D", disk, "-L", logdir, "-y"]
    libcalamares.utils.debug("Running setup-storage: {}".format(" ".join(command)))
    result = _run(command)
    output = (result.stdout or "") + (result.stderr or "")
    for line in output.splitlines():
        libcalamares.utils.debug("setup-storage: {}".format(line))
    if result.returncode != 0:
        tail = "\n".join(output.strip().splitlines()[-20:])
        raise StorageError(
            "setup-storage failed with exit code {}. Logs: {}\n{}".format(
                result.returncode, workdir, tail))
    return workdir


def _system_partitions(entries):
    partitions = []
    for entry in entries:
        uuid = _uuid(entry["device"])
        if not uuid:
            raise StorageError(
                "No filesystem UUID on {} after formatting.".format(entry["device"]))
        partition = {
            "device": entry["device"],
            "partlabel": _partlabel(entry["device"]),
            "partuuid": _partuuid(entry["device"]),
            "mountPoint": entry["mount"],
            "fsName": entry["fs"],
            "fs": entry["fs"],
            "features": {},
            "uuid": uuid,
            "claimed": True,
        }
        partitions.append(partition)
    return partitions


def _check_device_overlap(devices):
    for index, first in enumerate(devices):
        for second in devices[index + 1:]:
            if _parent_disk(first) == second or _parent_disk(second) == first:
                raise StorageError(
                    "{} contains {}, so both cannot be used as separate "
                    "data devices.".format(first, second))


def _check_data_device(device, install_disk):
    if not device:
        return
    if device.startswith(NETWORK_PREFIXES):
        raise StorageError("Refusing to format network block device: {}".format(device))
    if not _is_block(device):
        raise StorageError("Not a block device: {}".format(device))
    if device == install_disk:
        raise StorageError("The installation disk is also listed as a data device.")
    parent = _parent_disk(device)
    if parent == install_disk:
        raise StorageError(
            "{} is a partition of the installation disk.".format(device))

    for child, mountpoint in _mount_info(device):
        if not mountpoint:
            continue
        if mountpoint == "[SWAP]":
            _run(["swapoff", child], check=True)
            continue
        if mountpoint.startswith(LIVE_MOUNTS):
            raise StorageError(
                "Refusing to format {}: it is the live medium at {}".format(
                    device, mountpoint))
        if mountpoint in ("/", "/boot", "/boot/efi"):
            raise StorageError(
                "Refusing to format {}: it is in use at {}".format(child, mountpoint))
        # The live session may auto-mount a data disk. Unmount it before the
        # destructive write; if it cannot be unmounted, stop.
        result = _run(["umount", "-R", mountpoint])
        if result.returncode != 0 and "not mounted" not in result.stderr.lower():
            raise StorageError(
                "Cannot unmount {} from {}: {}".format(
                    child, mountpoint, result.stderr.strip()))


def _format_data(device, filesystem, label):
    _wipe(device)
    if filesystem == "btrfs":
        command = ["mkfs.btrfs", "-f", "-L", label]
    elif filesystem == "f2fs":
        command = ["mkfs.f2fs", "-f", "-l", label]
    elif filesystem == "ext4":
        command = ["mkfs.ext4", "-F", "-L", label]
    else:
        raise StorageError("Unsupported filesystem: {}".format(filesystem))
    _run(command + [device], check=True)


def _format_data_plan(install_disk):
    data = [item.strip() for item in _global("dataPlanDevices").split(",")
            if item.strip()]
    backup = _global("dataPlanBackup").strip()
    data_fs = _global("dataPlanFs")
    backup_fs = _global("dataPlanBackupFs")
    raid = _global("dataPlanRaid").lower()
    asis = _global("dataPlanAsIs").strip().lower() in ("true", "1", "yes")

    if not data and not backup:
        libcalamares.globalstorage.insert("dataFormatted", [])
        return

    if len(set(data)) != len(data):
        raise StorageError("The /data device list contains duplicates.")
    if backup and backup in data:
        raise StorageError("The backup device is also listed as a /data device.")

    for device in data + ([backup] if backup else []):
        _check_data_device(device, install_disk)

    formatted = []

    if data:
        if asis:
            if len(data) != 1:
                raise StorageError("Mount as-is requires exactly one data device.")
            existing_fs = _fstype(data[0])
            if existing_fs not in ("btrfs", "ext4", "f2fs", "xfs"):
                raise StorageError(
                    "The selected data device does not contain a supported "
                    "filesystem for as-is mounting.")
            uuid = _uuid(data[0])
            if not uuid:
                raise StorageError("Cannot determine the /data UUID.")
            formatted.append({
                "device": data[0],
                "fs": existing_fs,
                "uuid": uuid,
                "mountPoint": "/data",
                "role": "data",
                "options": "defaults,nofail,x-systemd.device-timeout=10",
            })
        elif data_fs not in ("btrfs", "f2fs", "ext4"):
            raise StorageError("Unsupported /data filesystem: {}".format(data_fs))
        elif len(data) == 1:
            _format_data(data[0], data_fs, DATA_LABEL)
            uuid = _uuid(data[0])
            if not uuid:
                raise StorageError("Cannot determine the /data UUID.")
            formatted.append({
                "device": data[0],
                "fs": data_fs,
                "uuid": uuid,
                "mountPoint": "/data",
                "role": "data",
                "options": "defaults,nofail,x-systemd.device-timeout=10",
            })
        else:
            if data_fs != "btrfs":
                raise StorageError("RAID requires btrfs.")
            if raid not in ("raid0", "raid1", "raid1c3", "raid1c4", "raid10"):
                raid = "raid1"
            for device in data:
                _wipe(device)
            _run(["mkfs.btrfs", "-f", "-d", raid, "-m", raid,
                  "-L", DATA_LABEL] + data, check=True)
            uuid = _uuid(data[0])
            if not uuid:
                raise StorageError("Cannot determine the btrfs RAID UUID.")
            options = "defaults,nofail,x-systemd.device-timeout=10"
            if raid != "raid0":
                options = "defaults,nofail,degraded,x-systemd.device-timeout=10"
            formatted.append({
                "device": data[0],
                "devices": data,
                "fs": "btrfs",
                "uuid": uuid,
                "mountPoint": "/data",
                "role": "data",
                "options": options,
            })

    if backup:
        if backup_fs not in ("btrfs", "f2fs", "ext4"):
            raise StorageError("Unsupported backup filesystem: {}".format(backup_fs))
        _format_data(backup, backup_fs, BACKUP_LABEL)
        uuid = _uuid(backup)
        if not uuid:
            raise StorageError("Cannot determine the /backups UUID.")
        formatted.append({
            "device": backup,
            "fs": backup_fs,
            "uuid": uuid,
            "mountPoint": "/backups",
            "role": "backup",
            "options": "defaults,noauto,nofail,x-systemd.device-timeout=10",
        })

    libcalamares.globalstorage.insert("dataFormatted", formatted)


def run():
    try:
        # Fail before the first destructive write if the second backup page
        # is enabled but its remote credentials are incomplete.
        _check_secondary_backup()

        install_disk = _global("localHostInstallDisk").strip()
        root_fs = _global("localHostFilesystem").strip().lower() or "btrfs"
        if root_fs not in ("btrfs", "ext4", "f2fs", "xfs"):
            root_fs = "btrfs"
        swap_choice = _global("localHostSwapChoice").strip() or "small"
        if swap_choice not in ("none", "small", "suspend"):
            swap_choice = "small"

        if not install_disk:
            raise StorageError("No installation disk was selected.")
        if install_disk.startswith(NETWORK_PREFIXES):
            raise StorageError(
                "Refusing to install on network block device {}".format(install_disk))
        if not _is_block(install_disk) or not _is_whole_disk(install_disk):
            raise StorageError(
                "{} is not a whole block device.".format(install_disk))

        disk_mib = _disk_mib(install_disk)
        if disk_mib < 8 * 1024:
            raise StorageError(
                "{} is too small for a system installation ({} MiB).".format(
                    install_disk, disk_mib))

        # Validate (and unmount) optional data devices before the system disk
        # is touched, so a bad data selection does not leave a half-wiped
        # installation disk behind.
        planned_data = [item.strip() for item in
                        _global("dataPlanDevices").split(",") if item.strip()]
        planned_backup = _global("dataPlanBackup").strip()
        if len(set(planned_data)) != len(planned_data):
            raise StorageError("The /data device list contains duplicates.")
        if planned_backup and planned_backup in planned_data:
            raise StorageError(
                "The backup device is also listed as a /data device.")
        data_fs = _global("dataPlanFs")
        asis = _global("dataPlanAsIs").strip().lower() in ("true", "1", "yes")
        if asis:
            if len(planned_data) != 1:
                raise StorageError(
                    "Mount as-is requires exactly one data device.")
        else:
            if planned_data and data_fs not in ("btrfs", "f2fs", "ext4"):
                raise StorageError(
                    "Unsupported /data filesystem: {}".format(data_fs))
            if len(planned_data) > 1 and data_fs != "btrfs":
                raise StorageError("RAID requires btrfs.")
        backup_fs = _global("dataPlanBackupFs")
        if planned_backup and backup_fs not in ("btrfs", "f2fs", "ext4"):
            raise StorageError(
                "Unsupported backup filesystem: {}".format(backup_fs))
        data_devices = planned_data + ([planned_backup] if planned_backup else [])
        _check_device_overlap(data_devices)
        for device in data_devices:
            _check_data_device(device, install_disk)

        entries = _layout(install_disk, swap_choice, root_fs)
        _unmount_disk(install_disk)
        workdir = _run_fai(install_disk, entries)
        _settle()

        root = next(entry for entry in entries if entry["role"] == "root")
        if root["fs"] == "btrfs":
            libcalamares.utils.debug(
                "Formatting btrfs root on {}".format(root["device"]))
            _run(["mkfs.btrfs", "-f", "-L", ROOT_LABEL, root["device"]],
                 check=True)
        else:
            libcalamares.utils.debug(
                "FAI created the {} root filesystem on {}".format(
                    root["fs"], root["device"]))

        partitions = _system_partitions(entries)
        libcalamares.globalstorage.insert("partitions", partitions)

        efi = _is_efi()
        libcalamares.globalstorage.insert(
            "firmwareType", "efi" if efi else "bios")
        libcalamares.globalstorage.insert(
            "efiSystemPartition", EFI_SYSTEM_PARTITION)
        libcalamares.globalstorage.insert(
            "bootLoader", {"installPath": install_disk})
        libcalamares.globalstorage.insert(
            "partitionChoices",
            {"install": "erase", "swap": swap_choice})

        _format_data_plan(install_disk)

        libcalamares.utils.debug(
            "setup-storage finished; work directory {}".format(workdir))
        return None
    except SecondaryBackupError as error:
        return ("Second backup configuration failed", str(error))
    except StorageError as error:
        return ("Storage setup failed", str(error))
    except Exception as error:  # noqa: BLE001
        return ("Storage setup failed", str(error))
