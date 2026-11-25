# openQA single-instance with a browser-playable video encoder and persistent
# state.
#
# os-autoinst's built-in encoder writes Theora OGV, which Chromium cannot play,
# so a job video looks empty in the web UI even though video.ogv is valid. With
# ffmpeg present, os-autoinst additionally records a VP9 WebM for the player.
ARG BASE_IMAGE=registry.opensuse.org/devel/openqa/containers/openqa-single-instance
FROM ${BASE_IMAGE}

RUN zypper --non-interactive install --no-recommends ffmpeg \
    && zypper clean -a

# The upstream image keeps its initialized state in the container layer. Keep a
# copy so the entrypoint can seed an empty named volume on first use instead of
# starting PostgreSQL and openQA from nothing.
RUN cp -a /var/lib/pgsql /var/lib/pgsql-image \
    && cp -a /var/lib/openqa /var/lib/openqa-image

COPY entrypoint.sh /usr/local/bin/local-host-openqa-entrypoint
ENTRYPOINT ["/bin/sh", "/usr/local/bin/local-host-openqa-entrypoint"]
