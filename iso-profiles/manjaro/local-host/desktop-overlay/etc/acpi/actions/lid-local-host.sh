#!/bin/sh
# Stop LightDM/X when a laptop lid is closed; start it again when opened.
# Do nothing in the live installer environment.

set -eu

case "${*:-}" in
    *close*) state=close ;;
    *open*)  state=open ;;
    *)       exit 0 ;;
esac

if [ -d /run/miso ]; then
    /usr/bin/logger -t lid-local-host "live session: ignoring lid $state"
    exit 0
fi

case "$state" in
    close)
        /usr/bin/logger -t lid-local-host "lid closed: stopping LightDM/X"
        /usr/bin/systemctl stop lightdm.service
        ;;
    open)
        /usr/bin/logger -t lid-local-host "lid opened: starting LightDM/X"
        /usr/bin/systemctl start lightdm.service
        ;;
esac
