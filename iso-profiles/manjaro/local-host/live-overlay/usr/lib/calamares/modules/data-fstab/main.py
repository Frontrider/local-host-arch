#!/usr/bin/env python3
"""Write /data and /backups into the target fstab and set up the backup."""

import base64
import os
import re
import subprocess

import libcalamares


class DataError(Exception):
    pass


def pretty_name():
    return "Configuring data storage"


def _run(args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


class DataFstab:
    def __init__(self):
        self.root = libcalamares.globalstorage.value("rootMountPoint")
        if not self.root:
            raise DataError("The target root is not mounted.")
        self.root = str(self.root)
        self.fstab = self._path("/etc/fstab")
        self.restic_password = "/etc/local-host/restic-password"
        self.systemd_dir = "/etc/systemd/system"

    def _path(self, target):
        return os.path.join(self.root, target.lstrip("/"))

    def _add_fstab(self, spec, mountpoint, filesystem, options):
        target_dir = self._path(mountpoint)
        os.makedirs(target_dir, exist_ok=True)
        if os.path.exists(self.fstab) and os.path.getsize(self.fstab):
            with open(self.fstab, "rb") as fstab:
                fstab.seek(-1, os.SEEK_END)
                if fstab.read(1) != b"\n":
                    with open(self.fstab, "ab") as append:
                        append.write(b"\n")
        with open(self.fstab, "a", encoding="utf-8") as fstab:
            fstab.write("UUID={} {} {} {} 0 0\n".format(
                spec, mountpoint, filesystem, options))

    def _has_mount(self, mountpoint):
        if not os.path.exists(self.fstab):
            return False
        with open(self.fstab, encoding="utf-8") as fstab:
            for line in fstab:
                fields = line.split()
                if len(fields) >= 2 and not fields[0].startswith("#") and fields[1] == mountpoint:
                    return True
        return False

    def _write(self, target, content, mode=0o644):
        path = self._path(target)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as output:
            output.write(content)
        os.chmod(path, mode)

    def _target_call(self, args):
        libcalamares.utils.check_target_env_call(args)

    def _target_output(self, args):
        return libcalamares.utils.check_target_env_output(args).strip()

    def _setup_backup_service(self, backup):
        if backup is not None:
            device = backup["device"]
            uuid = backup["uuid"]
            restic_bin = self._target_output(["sh", "-c", "command -v restic"])
            if not restic_bin:
                raise DataError("restic not found in the target.")

            password_path = self._path(self.restic_password)
            os.makedirs(os.path.dirname(password_path), exist_ok=True)
            if not os.path.exists(password_path) or os.path.getsize(password_path) == 0:
                password = base64.b64encode(os.urandom(32)).decode("ascii")
                with open(password_path, "w", encoding="ascii") as output:
                    output.write(password + "\n")
            os.chmod(password_path, 0o600)

            backup_dir = self._path("/backups")
            os.makedirs(backup_dir, exist_ok=True)
            mounted_here = False
            if not os.path.ismount(backup_dir):
                _ = _run(["mount", device, backup_dir])
                if _.returncode != 0:
                    raise DataError("Cannot mount {} on {}: {}".format(
                        device, backup_dir, _.stderr.strip()))
                mounted_here = True
            try:
                self._target_call([restic_bin, "--no-cache",
                                   "-r", "/backups/restic",
                                   "--password-file", self.restic_password,
                                   "init"])
            finally:
                if mounted_here:
                    _run(["umount", backup_dir])

        # NPBackup manages the existing restic repository from here on. The
        # config is generated per installation (never shipped in git), and
        # NPBackup encrypts its repo URI/password fields on first use.
        npbackup_config = """conf_version: 3.0.4
repos:
  default:
    repo_uri: /backups/restic
    repo_group: default_group
    backup_opts:
      paths:
        - /data
      source_type: folder_list
      tags:
        - local-host
    repo_opts:
      repo_password_command: cat /etc/local-host/restic-password
      retention_policy:
        last: 3
        hourly: 0
        daily: 7
        weekly: 4
        monthly: 12
        yearly: 2
        keep_within: true
        ntp_server: pool.ntp.org
        keep_tags: []
      compression: auto
    prometheus: {}
    env: {}
    is_protected: false
groups:
  default_group:
    backup_opts:
      paths: []
      source_type:
      stdin_from_command:
      stdin_filename:
      tags: []
      use_fs_snapshot: false
      ignore_cloud_files: true
      exclude_caches: true
      one_file_system: true
      priority: low
      excludes_case_ignore: false
      exclude_files:
        - excludes/generic_excluded_extensions
        - excludes/generic_excludes
        - excludes/linux_excludes
      exclude_patterns:
        - /data/backup
      exclude_files_larger_than:
      additional_parameters:
      additional_backup_only_parameters:
      minimum_backup_size_error: 0
      pre_exec_commands: []
      pre_exec_per_command_timeout: 3600
      pre_exec_failure_is_fatal: false
      post_exec_commands: []
      post_exec_per_command_timeout: 3600
      post_exec_failure_is_fatal: false
      post_exec_execute_even_on_backup_error: true
    repo_opts:
      repo_password_command: cat /etc/local-host/restic-password
      minimum_backup_age: 1440
      upload_speed: 0
      download_speed: 0
      backend_connections: 0
      retention_policy:
        last: 3
        hourly: 0
        daily: 7
        weekly: 4
        monthly: 12
        yearly: 2
        keep_within: true
        ntp_server: pool.ntp.org
        keep_tags: []
      compression: auto
    prometheus: {}
    env:
      env_variables: {}
      encrypted_env_variables: {}
    is_protected: false
identity:
  machine_id: local-host
  machine_group: local-host
global_prometheus:
  metrics: false
  instance: local-host
  destination:
global_email:
  enable: false
global_options:
  auto_upgrade: false
audience: private
"""
        if backup is None:
            # The second-backup module adds its own repository. Leave the base
            # config without a main repository in this case.
            npbackup_config = re.sub(
                r"  default:\n(?:    .*\n)+", "", npbackup_config, count=1)
        self._write("/etc/local-host/npbackup.conf", npbackup_config, mode=0o600)

        # The installer-created administrator is in wheel. Allow that group to
        # open the root GUI wrapper without a terminal, while keeping the
        # config, password and /backups root-only.
        sudoers = """Defaults:%wheel env_keep += "DISPLAY XAUTHORITY"
%wheel ALL=(root) NOPASSWD: /usr/local/bin/local-host-backup-gui
"""
        self._write("/etc/sudoers.d/20-local-host-backup-gui", sudoers, mode=0o440)
        self._target_call(
            ["visudo", "-cf", "/etc/sudoers.d/20-local-host-backup-gui"])

        if backup is None:
            return None

        service = """[Unit]
Description=local-host NPBackup backup
After=local-fs.target
RequiresMountsFor=/data
ConditionPathExists=/etc/local-host/npbackup.conf
ConditionPathExists=/dev/disk/by-uuid/{uuid}

[Service]
Type=oneshot
Environment=RESTIC_CACHE_DIR=/var/cache/restic
CacheDirectory=restic
CacheDirectoryMode=0700
ExecStart=/usr/local/bin/local-host-backup-run
""".format(uuid=uuid)
        self._write(self.systemd_dir + "/local-host-backup.service", service)

        timer = """[Unit]
Description=Daily local-host backup

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
"""
        self._write(self.systemd_dir + "/local-host-backup.timer", timer)

        housekeeping_service = """[Unit]
Description=local-host NPBackup housekeeping
After=local-fs.target
ConditionPathExists=/etc/local-host/npbackup.conf
ConditionPathExists=/dev/disk/by-uuid/{uuid}

[Service]
Type=oneshot
Environment=RESTIC_CACHE_DIR=/var/cache/restic
CacheDirectory=restic
CacheDirectoryMode=0700
ExecStart=/usr/local/bin/local-host-backup-housekeeping
""".format(uuid=uuid)
        self._write(
            self.systemd_dir + "/local-host-backup-housekeeping.service",
            housekeeping_service)

        housekeeping_timer = """[Unit]
Description=Weekly local-host backup housekeeping

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
"""
        self._write(
            self.systemd_dir + "/local-host-backup-housekeeping.timer",
            housekeeping_timer)

        wants = self._path(self.systemd_dir + "/timers.target.wants")
        os.makedirs(wants, exist_ok=True)
        for name in ("local-host-backup.timer",
                     "local-host-backup-housekeeping.timer"):
            link = os.path.join(wants, name)
            if os.path.lexists(link):
                os.unlink(link)
            os.symlink("../" + name, link)

    def run(self):
        entries = libcalamares.globalstorage.value("dataFormatted") or []
        for entry in entries:
            mountpoint = entry.get("mountPoint")
            if not mountpoint or self._has_mount(mountpoint):
                continue
            self._add_fstab(entry["uuid"], mountpoint, entry["fs"],
                            entry.get("options", "defaults,nofail"))

        backup = next(
            (entry for entry in entries if entry.get("role") == "backup"),
            None)
        secondary = str(
            libcalamares.globalstorage.value("secondaryBackupEnabled")
            or "").strip().lower() in ("true", "1", "yes")
        if backup is not None:
            self._setup_backup_service(backup)
        elif secondary:
            # Write the base NPBackup config without a main repository; the
            # second-backup job inserts its own repository for the GUI.
            self._setup_backup_service(None)
        return None


def run():
    try:
        return DataFstab().run()
    except DataError as error:
        return ("Data storage configuration failed", str(error))
    except Exception as error:  # noqa: BLE001
        return ("Data storage configuration failed", str(error))
