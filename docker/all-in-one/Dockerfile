# Sando Pulse — all-in-one image.
#
# ONE image: Pulse server + Postgres 16 (vector 0.6.0, PostGIS 3.4.2,
# pg_trgm 1.6) + Redis 7. Dominic runs a single `docker run` with no
# separate DB setup. Built from the verified Roadmap 6 head.
#
# OFFLINE BUILD: the Pulse binary is built on the host (Zig 0.17.1) and
# the Ubuntu 24.04 .debs are vendored in debs/ — no network is needed
# inside the build. See build.sh; the .debs are NOT committed to git
# (210 MB) — build.sh fetches them with apt-get download.
#
# The image runs as root: Postgres and Redis drop privileges via `su`
# in the entrypoint (Postgres refuses to run as root). The DB uses trust
# auth on localhost only — this image is for LOCAL use. Do not expose
# port 9000 publicly without setting PULSE_API_KEY.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Vendored Ubuntu 24.04 (noble) packages: Postgres 16 + PostGIS 3.4.2 +
# pgvector 0.6.0 + Redis 7.0 + curl (healthcheck). One dpkg invocation
# so configuration order is resolved by dpkg itself.
COPY docker/all-in-one/debs/*.deb /tmp/debs/
RUN dpkg -i /tmp/debs/*.deb \
    && rm -rf /tmp/debs \
    # Drop the cluster the postgresql-16 postinst created at install
    # time: the entrypoint creates its own data dir under /var/lib/postgresql/data.
    && rm -rf /etc/postgresql /var/lib/postgresql/16 \
    && mkdir -p /app /var/lib/postgresql/data /var/log/postgresql \
        /var/lib/redis /var/log/redis /var/run/postgresql \
    && chown -R postgres:postgres /var/lib/postgresql /var/log/postgresql /var/run/postgresql \
    && chown -R redis:redis /var/lib/redis /var/log/redis

# Pulse binary (built on the host by build.sh) + migrations + entrypoint.
COPY docker/all-in-one/pulse /usr/local/bin/pulse
COPY migrations /app/migrations
COPY docker/all-in-one/entrypoint.sh /usr/local/bin/pulse-entrypoint.sh
RUN chmod +x /usr/local/bin/pulse /usr/local/bin/pulse-entrypoint.sh

WORKDIR /app
VOLUME /var/lib/postgresql/data
EXPOSE 9000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PULSE_PORT:-9000}/v1/health"
ENTRYPOINT ["/usr/local/bin/pulse-entrypoint.sh"]
