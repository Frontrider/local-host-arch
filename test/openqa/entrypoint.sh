#!/bin/sh
#
# Entrypoint for the local-host openQA container.
#
# The upstream image runs the full openQA bootstrap on every start: package
# installation, web proxy setup, database setup and then the services. That is
# unnecessary for a persistent stack and makes every restart slow.
#
# This entrypoint runs the full bootstrap once per container. Later starts of
# the same container only bring the database, daemons and worker up. The
# database and openQA data live in named volumes, so recreating the container
# for a new image keeps the jobs, results and settings.
set -eu

# A named volume starts empty and would hide the initialized PostgreSQL cluster
# and the openQA directory skeleton that are baked into the image. Copy them in
# on the volume's first use.
seed_volume() {
    target=$1
    template=$2
    if [ ! -d "$target" ] || [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
        [ -d "$template" ] || return 0
        mkdir -p "$target"
        cp -a "$template"/. "$target"/
    fi
}

if [ ! -e /var/lib/pgsql/data/PG_VERSION ] && [ -d /var/lib/pgsql-image ]; then
    mkdir -p /var/lib/pgsql
    cp -a /var/lib/pgsql-image/. /var/lib/pgsql/
fi
seed_volume /var/lib/openqa /var/lib/openqa-image

# The marker is in the container's own layer, not in a volume: a restarted
# container skips the slow bootstrap, while a recreated container bootstraps
# again and keeps the volumes.
marker=/etc/openqa/.local-host-bootstrapped
if [ -e "$marker" ]; then
    /usr/share/openqa/script/openqa-bootstrap start
    exec sleep infinity
fi

/usr/share/openqa/script/openqa-bootstrap "$@" &
bootstrap=$!

# Only mark the container as bootstrapped once the web UI is reachable, so a
# crash during the bootstrap is retried on the next start.
while ! curl -fsS http://localhost/ >/dev/null 2>&1; do
    if ! kill -0 "$bootstrap" 2>/dev/null; then
        wait "$bootstrap"
        exit $?
    fi
    sleep 2
done
mkdir -p "$(dirname "$marker")"
: > "$marker"
wait "$bootstrap"
