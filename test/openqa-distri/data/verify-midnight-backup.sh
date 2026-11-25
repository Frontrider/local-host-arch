#!/usr/bin/env bash
# Run as root inside the disposable openQA guest.
set -euo pipefail

timer=local-host-backup.timer
service=local-host-backup.service
drop_in=
marker=
mounted_here=false

fail() { printf 'Backup check failed: %s\n' "$*" >&2; exit 1; }

cleanup() {
    local status=$?
    if ((status != 0)); then
        systemctl show "$timer" -p LastTriggerUSec || true
        journalctl -b -u "$service" -n 40 --no-pager || true
    fi
    if "$mounted_here"; then
        umount /backups || status=1
    fi
    if [[ -n $marker ]]; then
        rm -f -- "$marker" || status=1
    fi
    if [[ -n $drop_in ]]; then
        rm -f -- "$drop_in" || status=1
        systemctl daemon-reload && systemctl restart "$timer" || status=1
    fi
    exit "$status"
}
trap cleanup EXIT

[[ $(systemctl is-enabled "$timer") == enabled ]] || fail "$timer is not enabled"
systemctl is-active --quiet "$timer" || fail "$timer is not active"
calendar=$(systemctl show -P TimersCalendar "$timer")
[[ $calendar == *'OnCalendar=*-*-* 00:00:00 ;'* ]] ||
    fail "$timer does not have the midnight schedule"
[[ $(systemctl show -P ActiveState "$service") == inactive ]] ||
    fail "$service was not idle before the check"
! mountpoint -q /backups || fail "/backups was mounted before the check"

marker=$(mktemp /data/openqa-midnight-backup.XXXXXXXX)
printf 'openQA backup contents for %s\n' "${marker##*/}" > "$marker"
previous_start=$(systemctl show -P ExecMainStartTimestampMonotonic "$service")

# Use the actual installed timer and service, but advance the trigger without
# changing the guest clock or touching the installed unit.
dir="/run/systemd/system/$timer.d"
mkdir -p "$dir"
drop_in=$(mktemp --suffix=.conf "$dir/90-openqa.XXXXXXXX")
cat > "$drop_in" <<'EOF'
[Timer]
OnCalendar=
OnActiveSec=20s
AccuracySec=1s
Persistent=false
EOF
systemctl daemon-reload
previous_trigger=$(systemctl show -P LastTriggerUSecMonotonic "$timer")
systemctl restart "$timer"

# A default Result=success is also reported for a service that never ran.
# Require both a new timer trigger and a new, finished service invocation.
completed=false
for ((i = 0; i < 150; i++)); do
    trigger=$(systemctl show -P LastTriggerUSecMonotonic "$timer")
    start=$(systemctl show -P ExecMainStartTimestampMonotonic "$service")
    if [[ -n $trigger && $trigger != "$previous_trigger" &&
          -n $start && $start != "$previous_start" ]]; then
        case $(systemctl show -P ActiveState "$service") in
            failed) fail "$service failed after the timer triggered" ;;
            inactive) completed=true; break ;;
        esac
    fi
    sleep 1
done
"$completed" || fail "the timer did not complete a new backup"
[[ $(systemctl show -P Result "$service") == success ]] || fail "$service did not succeed"
! mountpoint -q /backups || fail "$service left /backups mounted"

mount /backups
mounted_here=true
restic --no-cache -r /backups/restic \
    --password-file /etc/local-host/restic-password dump latest "$marker" |
    cmp -s -- "$marker" - || fail "the latest snapshot did not contain the expected data"
printf 'Timer triggered the backup, unmounted the volume, and saved the test file.\n'
