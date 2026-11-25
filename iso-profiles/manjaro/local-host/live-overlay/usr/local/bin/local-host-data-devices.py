#!/usr/bin/env python3
"""Generate the Calamares Data storage device inventory.

The QML page reads the generated JavaScript. Run as root from
local-host-data-devices.service and from a udev rule.
"""

import fcntl
import json
import os
import shutil
import subprocess
import tempfile
import time

OUT_JS = os.environ.get(
    "LOCALHOST_DATA_JS",
    "/usr/local/share/local-host/calamares-data-devices.js",
)
LOCK = os.environ.get("LOCALHOST_DATA_LOCK", "/run/local-host-data-devices.lock")

COLUMNS = "NAME,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINT,PKNAME,RO,PARTTYPENAME,PARTUUID,TRAN,VENDOR,MODEL"
EXCLUDED_FS = {"swap", "squashfs", "iso9660", "crypto_LUKS", "LVM2_member",
               "linux_raid_member"}
SKIP_MOUNTS = ("/", "/boot", "/boot/efi")
LIVE_MOUNTS = ("/run/miso/bootmnt", "/run/archiso/bootmnt", "/run/ventoy")
NETWORK_TRANSPORTS = {"iscsi", "nbd", "fc", "fcoe", "rbd", "ceph", "tcp"}
VIRTUAL_PREFIXES = ("/dev/zram", "/dev/ram", "/dev/loop", "/dev/dm-", "/dev/md",
                    "/dev/sr", "/dev/fd")


def run(args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def text(value):
    return "" if value is None else str(value)


def normalize_device(value):
    value = text(value).strip()
    if not value:
        return ""
    return value if value.startswith("/") else "/dev/" + value


def clean_label(value):
    return text(value).translate(str.maketrans("|,;&<>'", "-------"))


def human_size(size):
    try:
        size = int(size)
    except (TypeError, ValueError):
        return "0B"
    if shutil.which("numfmt"):
        environment = dict(os.environ)
        environment["LC_ALL"] = "C"
        result = subprocess.run(["numfmt", "--to=iec-i", "--suffix=B", str(size)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=environment)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB")
    value = float(size)
    index = 0
    while value >= 1024.0 and index < len(units) - 1:
        value /= 1024.0
        index += 1
    if index == 0:
        return "{}B".format(int(value))
    return "{:.1f}{}".format(value, units[index])


def brand_text(vendor, model, tran):
    vendor = text(vendor).strip()
    model = text(model).strip()
    if vendor and model:
        return vendor + " " + model
    if model:
        return model
    if vendor:
        return vendor
    return text(tran).strip()


def item_label(label, fs, size, vendor, model, tran):
    parts = []
    brand = brand_text(vendor, model, tran)
    if brand:
        parts.append(brand)
    label = text(label).strip()
    if label:
        parts.append(label)
    elif fs:
        parts.append(fs)
    else:
        parts.append(size)
    if size and (label or fs):
        parts.append(size)
    return clean_label(" • ".join(parts))


def flatten(devices):
    result = []
    for device in devices:
        result.append(device)
        result.extend(flatten(device.get("children") or []))
    return result


def device_name(device):
    return normalize_device(device.get("name"))


def parent_name(device):
    return normalize_device(device.get("pkname"))


def is_read_only(device):
    return device.get("ro") is True or text(device.get("ro")).lower() in ("1", "true")


def is_virtual(name):
    return name.startswith(VIRTUAL_PREFIXES)


def is_boot_partition(device):
    parttype = text(device.get("parttypename")).lower()
    return "efi" in parttype or ("bios" in parttype and "boot" in parttype)


def live_disk_of(source):
    source = text(source).strip()
    if not source or not os.path.exists(source):
        return ""
    for field in ("PKNAME", "KNAME"):
        result = run(["lsblk", "-no", field, "-p", source])
        if result.returncode == 0:
            lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
            if lines:
                return normalize_device(lines[0])
    return ""


def acquire_lock():
    try:
        lock = open(LOCK, "w", encoding="utf-8")
    except OSError:
        return None
    deadline = time.monotonic() + 10
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock
        except BlockingIOError:
            if time.monotonic() >= deadline:
                lock.close()
                return None
            time.sleep(0.1)


def main():
    os.makedirs(os.path.dirname(OUT_JS) or ".", exist_ok=True)
    lock = acquire_lock()
    if lock is None:
        return 0

    result = run(["lsblk", "-J", "-b", "-p", "-o", COLUMNS])
    try:
        devices = json.loads(result.stdout).get("blockdevices", []) if result.returncode == 0 else []
    except (ValueError, AttributeError):
        devices = []
    rows = flatten(devices)
    transports = {}
    for device in rows:
        name = device_name(device)
        if name:
            transports[name] = text(device.get("tran")).lower()

    def is_network(device):
        name = device_name(device)
        parent = parent_name(device)
        lowered = name.lower()
        if "nbd" in lowered or "rbd" in lowered or "drbd" in lowered:
            return True
        transport = transports.get(name) or transports.get(parent, "")
        return transport in NETWORK_TRANSPORTS

    live_disks = set()
    disks_with_children = set()
    boot_disks = set()

    for device in rows:
        parent = parent_name(device)
        if parent:
            disks_with_children.add(parent)
        if device.get("children"):
            disks_with_children.add(device_name(device))

        if is_boot_partition(device) and parent:
            boot_disks.add(parent)

        # A live ISO (or a squashfs-based recovery image) is never a valid
        # installation target, even if its mount could not be identified.
        if parent and text(device.get("fstype")) in ("iso9660", "squashfs"):
            live_disks.add(parent)

        mountpoint = text(device.get("mountpoint"))
        if mountpoint in SKIP_MOUNTS and parent:
            boot_disks.add(parent)
        if mountpoint.startswith(("/run/miso", "/run/archiso", "/run/ventoy")):
            live_disks.add(device_name(device))
            if parent:
                live_disks.add(parent)

    for mountpoint in LIVE_MOUNTS:
        found = run(["findmnt", "-n", "-o", "SOURCE", "--target", mountpoint])
        if found.returncode != 0:
            continue
        source = found.stdout.splitlines()[0].strip() if found.stdout.splitlines() else ""
        disk = live_disk_of(source)
        if disk:
            live_disks.add(disk)

    disk_details = {}
    for device in rows:
        if text(device.get("type")) == "disk":
            disk_details[device_name(device)] = {
                "vendor": text(device.get("vendor")),
                "model": text(device.get("model")),
                "tran": text(device.get("tran")),
            }

    items = []

    def add_item(device, kind):
        name = device_name(device)
        if not name or is_virtual(name):
            return
        if is_network(device):
            return
        if is_read_only(device):
            return
        fs = text(device.get("fstype"))
        if kind == "partition" and fs in EXCLUDED_FS:
            return
        if kind == "partition" and is_boot_partition(device):
            return
        if kind == "partition":
            parent = parent_name(device)
            disk = parent or name
            if disk in live_disks or name in live_disks:
                return
            mountpoint = text(device.get("mountpoint"))
            if mountpoint in SKIP_MOUNTS or mountpoint.startswith(
                    ("/run/miso", "/run/archiso", "/run/ventoy", "/run/udev")):
                return
            details = disk_details.get(parent, {})
            vendor = text(device.get("vendor")) or details.get("vendor", "")
            model = text(device.get("model")) or details.get("model", "")
            tran = text(device.get("tran")) or details.get("tran", "")
            label = text(device.get("label"))
            size = human_size(device.get("size"))
            id_label = item_label(label, fs, size, vendor, model, tran)
            items.append({
                "id": "{}|{}".format(id_label, name),
                "kind": "partition",
                "path": name,
                "label": label,
                "vendor": vendor,
                "model": model,
                "size": size,
                "fs": fs,
                "tran": tran,
                "mountedAt": mountpoint,
                "parent": parent,
                "partuuid": text(device.get("partuuid")),
                "partitioned": False,
            })
            return

        if name in live_disks or name in boot_disks:
            return
        mountpoint = text(device.get("mountpoint"))
        if mountpoint in SKIP_MOUNTS or mountpoint.startswith(
                ("/run/miso", "/run/archiso", "/run/ventoy", "/run/udev")):
            return
        label = text(device.get("label"))
        size = human_size(device.get("size"))
        vendor = text(device.get("vendor"))
        model = text(device.get("model"))
        tran = text(device.get("tran"))
        id_label = item_label(label, fs, size, vendor, model, tran)
        items.append({
            "id": "{}|{}".format(id_label, name),
            "kind": "disk",
            "path": name,
            "label": label,
            "vendor": vendor,
            "model": model,
            "size": size,
            "fs": fs,
            "tran": tran,
            "mountedAt": mountpoint,
            "parent": "",
            "partuuid": text(device.get("partuuid")),
            "partitioned": name in disks_with_children,
        })

    for device in rows:
        if text(device.get("type")) == "part":
            add_item(device, "partition")
    for device in rows:
        if text(device.get("type")) == "disk":
            add_item(device, "disk")

    # Whole disks that can receive the boot/system installation. Unlike the
    # data list, this keeps disks that already contain an operating system:
    # reinstalling onto the current system disk is a normal use case. Only the
    # live medium, read-only devices and network block devices are excluded.
    install_items = []
    for device in rows:
        if text(device.get("type")) != "disk":
            continue
        name = device_name(device)
        if not name or is_virtual(name) or is_network(device) or is_read_only(device):
            continue
        try:
            if int(device.get("size") or 0) <= 0:
                continue
        except (TypeError, ValueError):
            continue
        if name in live_disks:
            continue
        mountpoint = text(device.get("mountpoint"))
        if mountpoint in SKIP_MOUNTS or mountpoint.startswith(
                ("/run/miso", "/run/archiso", "/run/ventoy", "/run/udev")):
            continue
        install_items.append({
            "kind": "disk",
            "path": name,
            "label": text(device.get("label")),
            "vendor": text(device.get("vendor")),
            "model": text(device.get("model")),
            "size": human_size(device.get("size")),
            "fs": text(device.get("fstype")),
            "tran": text(device.get("tran")),
            "partitioned": name in disks_with_children,
        })
    install_items.sort(key=lambda item: item["path"])

    generated = ["// Generated by local-host-data-devices.py at {}Z. Do not edit.".format(
        time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())), ".pragma library", "var devices = ["]
    generated.append('    { "id": "", "kind": "none", "path": "", "label": "", '
                     '"size": "", "fs": "", "mountedAt": "", "parent": "", '
                     '"partuuid": "", "partitioned": false },')
    for item in items:
        fields = []
        for key in ("id", "kind", "path", "label", "vendor", "model", "size",
                    "fs", "tran", "mountedAt", "parent", "partuuid"):
            fields.append('"{}": {}'.format(key, json.dumps(item[key], ensure_ascii=False)))
        fields.append('"partitioned": {}'.format("true" if item["partitioned"] else "false"))
        generated.append("    { " + ", ".join(fields) + " },")
    generated.append("];")

    generated.append("var installDisks = [")
    for item in install_items:
        fields = []
        for key in ("kind", "path", "label", "vendor", "model", "size", "fs", "tran"):
            fields.append('"{}": {}'.format(key, json.dumps(item[key], ensure_ascii=False)))
        fields.append('"partitioned": {}'.format("true" if item["partitioned"] else "false"))
        generated.append("    { " + ", ".join(fields) + " },")
    generated.append("];")

    directory = os.path.dirname(OUT_JS) or "."
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=os.path.basename(OUT_JS) + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write("\n".join(generated) + "\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, OUT_JS)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
