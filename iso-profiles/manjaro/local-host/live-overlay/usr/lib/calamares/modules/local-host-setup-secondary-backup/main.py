#!/usr/bin/env python3
"""Configure the second restic backup and its rclone mirror.

The second backup is independent from the NPBackup-managed /data backup:

  * it has its own restic password (restic-secondary-password),
  * it only contains /data/data/backed-up, and
  * its repository lives either on the backup drive (/backups/restic-secondary)
    or under /data/backup/restic-secondary.

When the user configured Google Drive, OneDrive, WebDAV or FTP on the second
backup page, this job also writes the rclone configuration and a systemd
service that mirrors the restic repository to that remote after every backup.

The page stores everything in Global Storage; this job writes only files in
the target system.
"""

import base64
import json
import os
import shlex

import libcalamares


SOURCE = "/data/data/backed-up"
PASSWORD_FILE = "/etc/local-host/restic-secondary-password"
MAIN_PASSWORD_FILE = "/etc/local-host/restic-password"
RCLONE_CONFIG = "/etc/local-host/secondary-rclone.conf"
CONFIG_FILE = "/etc/local-host/secondary-backup.conf"
REPO_DRIVE = "/backups/restic-secondary"
REPO_DATA = "/data/backup/restic-secondary"
REMOTE_NAME = "local-host-backup"
SYSTEMD_DIR = "/etc/systemd/system"


class SecondaryBackupError(Exception):
    pass


def pretty_name():
    return "Configuring the second backup"


def _global(key):
    value = libcalamares.globalstorage.value(key)
    return "" if value is None else str(value)


def _one_line(value):
    """Collapse a value to one config line (tokens are pasted as JSON)."""
    return " ".join(str(value or "").split())


def _json_token(value, provider):
    token = _one_line(value)
    if not token:
        raise SecondaryBackupError(
            "A {} token is required for the second backup.".format(provider))
    try:
        parsed = json.loads(token)
    except ValueError as error:
        raise SecondaryBackupError(
            "The {} token is not valid JSON: {}".format(provider, error))
    if not isinstance(parsed, dict):
        raise SecondaryBackupError(
            "The {} token must be a JSON object.".format(provider))
    return token


class SecondaryBackup:
    def __init__(self):
        self.root = libcalamares.globalstorage.value("rootMountPoint")
        if not self.root:
            raise SecondaryBackupError("The target root is not mounted.")
        self.root = str(self.root)
        self.entries = libcalamares.globalstorage.value("dataFormatted") or []

    def _path(self, target):
        return os.path.join(self.root, target.lstrip("/"))

    def _write(self, target, content, mode=0o644):
        path = self._path(target)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as output:
            output.write(content)
        os.chmod(path, mode)

    def _read(self, target):
        path = self._path(target)
        try:
            with open(path, encoding="ascii") as source:
                return source.read().strip()
        except OSError:
            return ""

    def _backup_uuid(self):
        for entry in self.entries:
            if entry.get("role") == "backup" and entry.get("uuid"):
                return str(entry["uuid"])
        return ""

    def _ensure_password(self):
        path = self._path(PASSWORD_FILE)
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return

        main_password = self._read(MAIN_PASSWORD_FILE)
        password = base64.b64encode(os.urandom(32)).decode("ascii")
        while password == main_password:
            password = base64.b64encode(os.urandom(32)).decode("ascii")

        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="ascii") as output:
            output.write(password + "\n")
        os.chmod(path, 0o600)

    def _obscure(self, password):
        if not password:
            return ""
        try:
            output = libcalamares.utils.check_target_env_output(
                ["rclone", "obscure", "--", password]).strip()
        except Exception as error:  # noqa: BLE001
            raise SecondaryBackupError(
                "Cannot obscure the rclone password: {}".format(error))
        lines = [line.strip() for line in output.splitlines() if line.strip()]
        if not lines:
            raise SecondaryBackupError(
                "rclone obscure returned an empty password.")
        return lines[-1]

    def _rclone_config(self):
        provider = _global("secondaryBackupProvider").strip().lower()
        if provider not in ("drive", "onedrive", "webdav", "ftp"):
            return "", ""

        lines = ["[{}]".format(REMOTE_NAME)]
        parts = [part for part in
                 _one_line(_global("secondaryBackupRemotePath")).split("/")
                 if part not in ("", ".", "..")]
        path = "/".join(parts)
        if not path:
            # Never mirror the repository into the remote root: rclone sync
            # would delete unrelated files there.
            path = "local-host-backup"
        remote = REMOTE_NAME + ":" + path

        if provider == "drive":
            token = _json_token(
                _global("secondaryBackupGoogleToken"), "Google Drive")
            lines += ["type = drive", "scope = drive", "token = " + token]
            client_id = _one_line(_global("secondaryBackupGoogleClientId"))
            client_secret = _one_line(_global("secondaryBackupGoogleClientSecret"))
            root_folder = _one_line(_global("secondaryBackupGoogleRootFolderId"))
            if client_id:
                lines.append("client_id = " + client_id)
            if client_secret:
                lines.append("client_secret = " + client_secret)
            if root_folder:
                lines.append("root_folder_id = " + root_folder)
        elif provider == "onedrive":
            token = _json_token(
                _global("secondaryBackupOneDriveToken"), "OneDrive")
            lines += ["type = onedrive", "token = " + token]
            client_id = _one_line(_global("secondaryBackupOneDriveClientId"))
            client_secret = _one_line(_global("secondaryBackupOneDriveClientSecret"))
            drive_id = _one_line(_global("secondaryBackupOneDriveDriveId"))
            drive_type = _one_line(_global("secondaryBackupOneDriveDriveType"))
            if client_id:
                lines.append("client_id = " + client_id)
            if client_secret:
                lines.append("client_secret = " + client_secret)
            if drive_id:
                lines.append("drive_id = " + drive_id)
            if drive_type:
                lines.append("drive_type = " + drive_type)
        elif provider == "webdav":
            url = _one_line(_global("secondaryBackupWebdavUrl"))
            if not url:
                raise SecondaryBackupError(
                    "A WebDAV URL is required for the second backup.")
            lines += ["type = webdav", "vendor = other", "url = " + url]
            user = _global("secondaryBackupWebdavUser")
            password = _global("secondaryBackupWebdavPass")
            if user:
                lines.append("user = " + _one_line(user))
            if password:
                lines.append("pass = " + self._obscure(password))
        elif provider == "ftp":
            host = _one_line(_global("secondaryBackupFtpHost"))
            if not host:
                raise SecondaryBackupError(
                    "An FTP host is required for the second backup.")
            port = _one_line(_global("secondaryBackupFtpPort")) or "21"
            if not port.isdigit():
                raise SecondaryBackupError(
                    "The FTP port must be a number: {}".format(port))
            lines += ["type = ftp", "host = " + host, "port = " + port]
            user = _global("secondaryBackupFtpUser")
            password = _global("secondaryBackupFtpPass")
            if user:
                lines.append("user = " + _one_line(user))
            if password:
                lines.append("pass = " + self._obscure(password))
            lines.append(
                "tls = " + ("true" if _global("secondaryBackupFtpTls") == "true"
                            else "false"))
            lines.append(
                "explicit_tls = "
                + ("true" if _global("secondaryBackupFtpExplicitTls") == "true"
                   else "false"))

        return "\n".join(lines) + "\n", remote

    def _write_config(self, location, remote):
        repo = REPO_DRIVE if location == "drive" else REPO_DATA
        values = [
            ("SECONDARY_BACKUP_ENABLED", "1"),
            ("SECONDARY_BACKUP_LOCATION", location),
            ("SECONDARY_BACKUP_REPO", repo),
            ("SECONDARY_BACKUP_PASSWORD_FILE", PASSWORD_FILE),
            ("SECONDARY_BACKUP_SOURCE", SOURCE),
            ("SECONDARY_BACKUP_RCLONE_CONFIG", RCLONE_CONFIG),
            ("SECONDARY_BACKUP_REMOTE", remote),
        ]
        contents = "# Generated by local-host-setup-secondary-backup. Do not edit.\n"
        for key, value in values:
            contents += "{}={}\n".format(key, shlex.quote(value))
        self._write(CONFIG_FILE, contents, mode=0o600)

    def _conditions(self, location, provider, backup_uuid):
        conditions = ""
        if location == "drive" and backup_uuid:
            conditions += "ConditionPathExists=/dev/disk/by-uuid/{}\n".format(
                backup_uuid)
        if provider != "none":
            conditions += "ConditionPathExists={}\n".format(RCLONE_CONFIG)
        return conditions

    def _write_units(self, location, provider, backup_uuid):
        conditions = self._conditions(location, provider, backup_uuid)

        service = """[Unit]
Description=local-host secondary restic backup
After=local-fs.target local-host-backup.service network-online.target
Wants=network-online.target
RequiresMountsFor=/data
ConditionPathExists={config}
ConditionPathExists={password}
{conditions}
[Service]
Type=oneshot
Environment=HOME=/root
Environment=RESTIC_CACHE_DIR=/var/cache/restic-secondary
CacheDirectory=restic-secondary
CacheDirectoryMode=0700
ExecStart=/bin/sh /usr/local/bin/local-host-backup-secondary-run
""".format(config=CONFIG_FILE, password=PASSWORD_FILE,
           conditions=conditions)
        self._write(SYSTEMD_DIR + "/local-host-backup-secondary.service", service)

        timer = """[Unit]
Description=Daily local-host secondary backup

[Timer]
OnCalendar=*-*-* 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
"""
        self._write(SYSTEMD_DIR + "/local-host-backup-secondary.timer", timer)

        housekeeping_service = """[Unit]
Description=local-host secondary backup housekeeping
After=local-fs.target local-host-backup-housekeeping.service network-online.target
Wants=network-online.target
RequiresMountsFor=/data
ConditionPathExists={config}
ConditionPathExists={password}
{conditions}
[Service]
Type=oneshot
Environment=HOME=/root
Environment=RESTIC_CACHE_DIR=/var/cache/restic-secondary
CacheDirectory=restic-secondary
CacheDirectoryMode=0700
ExecStart=/bin/sh /usr/local/bin/local-host-backup-secondary-housekeeping
""".format(config=CONFIG_FILE, password=PASSWORD_FILE, conditions=conditions)
        self._write(
            SYSTEMD_DIR + "/local-host-backup-secondary-housekeeping.service",
            housekeeping_service)

        housekeeping_timer = """[Unit]
Description=Weekly local-host secondary backup housekeeping

[Timer]
OnCalendar=Sun *-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
"""
        self._write(
            SYSTEMD_DIR + "/local-host-backup-secondary-housekeeping.timer",
            housekeeping_timer)

        wants = self._path(SYSTEMD_DIR + "/timers.target.wants")
        os.makedirs(wants, exist_ok=True)
        for name in ("local-host-backup-secondary.timer",
                     "local-host-backup-secondary-housekeeping.timer"):
            link = os.path.join(wants, name)
            if os.path.lexists(link):
                os.unlink(link)
            os.symlink("../" + name, link)

    def run(self):
        if _global("secondaryBackupEnabled").strip().lower() not in (
                "true", "1", "yes"):
            return None

        location = _global("secondaryBackupLocation").strip().lower() or "data"
        if location not in ("drive", "data"):
            location = "data"

        backup_uuid = self._backup_uuid()
        if location == "drive" and not backup_uuid:
            raise SecondaryBackupError(
                "The backup drive was selected for the second backup, but no "
                "backup drive was configured on the storage pages.")

        provider = _global("secondaryBackupProvider").strip().lower() or "none"
        if provider not in ("none", "drive", "onedrive", "webdav", "ftp"):
            raise SecondaryBackupError(
                "Unsupported second backup remote: {}".format(provider))

        rclone_config, remote = self._rclone_config()
        if rclone_config:
            self._write(RCLONE_CONFIG, rclone_config, mode=0o600)

        self._ensure_password()
        self._write_config(location, remote)
        self._write_units(location, provider, backup_uuid)

        # The commands are invoked through /bin/sh by systemd, but keep them
        # executable for manual runs from the installed system as well.
        for script in ("/usr/local/bin/local-host-backup-secondary-run",
                       "/usr/local/bin/local-host-backup-secondary-housekeeping"):
            path = self._path(script)
            if os.path.exists(path):
                os.chmod(path, 0o755)

        libcalamares.utils.debug(
            "secondary backup configured: location={} provider={} remote={}".format(
                location, provider, remote))
        return None


def run():
    try:
        return SecondaryBackup().run()
    except SecondaryBackupError as error:
        return ("Second backup configuration failed", str(error))
    except Exception as error:  # noqa: BLE001
        return ("Second backup configuration failed", str(error))
