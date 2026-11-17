# Sando Pulse — all-in-one image.
#
# ONE image: Pulse server + Postgres 16 (vector 0.6.0, PostGIS 3.4.2,
# pg_trgm 1.6) + Redis 7.0 + SearXNG (bundled web search, six engines,
# limiter on the same Redis db 1). Dominic runs a single `docker run`
# with no separate DB setup — web search works out of the box.
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
# dpkg -i in three passes: python3 has a pre-dependency chain
# (python3.12-minimal -> python3-minimal -> python3) and dpkg only
# configures a package after ALL unpacking in a pass, so a
# pre-dependency must be CONFIGURED in an earlier pass than the
# package that pre-depends on it — a chain of length N needs N
# passes. Pass 1 installs everything except python3-minimal and
# python3; pass 2 adds python3-minimal; pass 3 adds python3.
# (apt-get install cannot do this: it fails local-.deb upgrades
# with "Pathname to install is not absolute" — verified live.)
RUN dpkg -i /tmp/debs/*.deb || true; \
    dpkg -i /tmp/debs/*.deb || true; \
    dpkg -i /tmp/debs/*.deb \
    && rm -rf /tmp/debs \
    # Drop the cluster the postgresql-16 postinst created at install
    # time: the entrypoint creates its own data dir under /var/lib/postgresql/data.
    && rm -rf /etc/postgresql /var/lib/postgresql/16 \
    && mkdir -p /app /var/lib/postgresql/data /var/log/postgresql \
        /var/lib/redis /var/log/redis /var/run/postgresql \
    && chown -R postgres:postgres /var/lib/postgresql /var/log/postgresql /var/run/postgresql \
    && chown -R redis:redis /var/lib/redis /var/log/redis

# SearXNG (bundled web search): source + wheels are staged by build.sh
# step 2.5 and installed offline — no network inside the image build.
# The PyPI package named `searxng` is an unrelated MCP wrapper; the
# engine comes from its GitHub repo at the pinned commit. Only six
# engines are enabled (docker/searxng/settings-aio.yml); the limiter
# reuses this image's Redis (db 1) — no Valkey process is started.
COPY docker/all-in-one/searxng-src /tmp/searxng-src
COPY docker/all-in-one/wheelhouse /tmp/wheelhouse
COPY docker/searxng/settings-aio.yml /etc/searxng/settings.yml
# limiter.toml lives next to the settings: SearXNG reads it from the
# settings directory. Without it the bundled defaults apply, whose
# pass_ip list is EMPTY — localhost is rate-limited and the Pulse
# API's own searches get 429. The shipped file passlists 127.0.0.0/8
# (the API calls from localhost) + the compose network.
COPY docker/searxng/limiter.toml /etc/searxng/limiter.toml
# SearXNG runs in its own venv (/opt/searxng-venv): Ubuntu disables
# ensurepip for the SYSTEM python entirely ("ensurepip is disabled
# in Debian/Ubuntu for the system python"), so pip can only be
# bootstrapped inside a venv. The venv creation needs the
# python3-venv + python3-pip-whl + python3-setuptools-whl debs
# (vendored in step 2). Same two-step install as the smoke test:
# requirements first, then the package with --no-build-isolation
# (setup.py imports searx, which needs msgspec already installed).
RUN python3 -m venv /opt/searxng-venv \
    && /opt/searxng-venv/bin/python -m pip install --no-index --no-cache-dir --find-links /tmp/wheelhouse setuptools wheel -r /tmp/searxng-src/requirements.txt -r /tmp/searxng-src/requirements-server.txt \
    && /opt/searxng-venv/bin/python -m pip install --no-index --no-cache-dir --no-build-isolation --find-links /tmp/wheelhouse /tmp/searxng-src \
    && rm -rf /tmp/searxng-src /tmp/wheelhouse /root/.cache \
    && mkdir -p /var/log/searxng \
    && /opt/searxng-venv/bin/python -c "import searx; print('searxng installed')"

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
