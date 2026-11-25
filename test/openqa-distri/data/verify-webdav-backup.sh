#!/usr/bin/env bash
# Run as root inside the disposable openQA guest.
set -euo pipefail

folder=${1:?missing WebDAV test folder}
service=local-host-backup-secondary.service
marker=
fail() { printf 'WebDAV backup check failed: %s\n' "$*" >&2; exit 1; }

cleanup() {
    local status=$?
    if ((status != 0)); then
        journalctl -b -u "$service" -n 40 --no-pager || true
    fi
    if [[ -n $marker ]]; then
        rm -f -- "$marker" || status=1
    fi
    exit "$status"
}
trap cleanup EXIT

# Validate the installer-generated settings before running a destructive
# mirror: the service must only sync to this job's isolated test directory.
# shellcheck source=/dev/null
source /etc/local-host/secondary-backup.conf
[[ $SECONDARY_BACKUP_ENABLED == 1 && $SECONDARY_BACKUP_LOCATION == drive &&
   $SECONDARY_BACKUP_REPO == /backups/restic-secondary ]] || fail "backup drive configuration is incorrect"
[[ $folder == openqa-job-* && $SECONDARY_BACKUP_REMOTE == "local-host-backup:$folder" ]] ||
    fail "the remote directory does not belong to this job"
grep -Fxq 'type = webdav' "$SECONDARY_BACKUP_RCLONE_CONFIG" &&
    grep -Fxq 'url = http://10.0.2.2:8081' "$SECONDARY_BACKUP_RCLONE_CONFIG" ||
    fail "the installed configuration does not point to the WebDAV test server"

! mountpoint -q /backups || fail "/backups was already mounted"
mkdir -p /data/data/backed-up
marker=$(mktemp /data/data/backed-up/openqa-webdav.XXXXXXXX)
printf 'openQA WebDAV backup contents for %s\n' "${marker##*/}" > "$marker"
timeout 120s systemctl start "$service" || fail "$service did not complete successfully"
[[ $(systemctl show -P Result "$service") == success ]] || fail "$service did not succeed"
! mountpoint -q /backups || fail "$service left /backups mounted"

# Read from WebDAV itself while the backup volume is unmounted. A successful
# sync exit is not sufficient evidence that the uploaded snapshot is usable.
RCLONE_CONFIG="$SECONDARY_BACKUP_RCLONE_CONFIG" timeout 60s restic --no-cache \
    --repo "rclone:$SECONDARY_BACKUP_REMOTE" --password-file "$SECONDARY_BACKUP_PASSWORD_FILE" \
    dump latest "$marker" | cmp -s -- "$marker" - ||
    fail "the remote restic snapshot did not contain the expected data"
printf 'Restored the exact test file from the WebDAV snapshot.\n'
