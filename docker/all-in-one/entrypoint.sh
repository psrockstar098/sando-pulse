#!/bin/bash
# pulse-entrypoint.sh — all-in-one startup: Postgres + Redis + SearXNG + Pulse.
#
# First run: initdb a fresh Postgres data dir, create the pulse database.
# Every run: start Postgres and Redis if not already running, then exec
# `pulse serve` (Pulse migrates on boot). Data persists in the
# /var/lib/postgresql/data volume.
#
# Ports are overridable for hosts that already run Postgres/Redis:
#   PULSE_PG_PORT (default 5432), PULSE_REDIS_PORT (default 6379),
#   PULSE_PORT (default 9000), PULSE_PG_DB (default pulse).
# DATABASE_URL / REDIS_URL, if set, win over the derived defaults.
#
# Auth: Postgres uses trust on localhost only, superuser `postgres`.
# This image is for LOCAL use — do not expose port 9000 publicly
# without setting PULSE_API_KEY.
set -euo pipefail

PGDATA="${PULSE_PGDATA:-/var/lib/postgresql/data}"
PGPORT="${PULSE_PG_PORT:-5432}"
PGDATABASE="${PULSE_PG_DB:-pulse}"
REDISPORT="${PULSE_REDIS_PORT:-6379}"
PULSE_HOST="${PULSE_HOST:-0.0.0.0}"
PULSE_PORT="${PULSE_PORT:-9000}"

export DATABASE_URL="${DATABASE_URL:-postgres://postgres@127.0.0.1:${PGPORT}/${PGDATABASE}}"
export REDIS_URL="${REDIS_URL:-redis://127.0.0.1:${REDISPORT}}"
export PULSE_HOST PULSE_PORT

PG_BIN=/usr/lib/postgresql/16/bin

# /var/run is tmpfs: recreate the socket dir on every container start.
mkdir -p /var/run/postgresql /var/lib/redis /var/log/redis
chown postgres:postgres /var/run/postgresql
chown redis:redis /var/lib/redis /var/log/redis

# --- Postgres: init on first run -------------------------------------------
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "[entrypoint] initialising postgres data dir $PGDATA"
    mkdir -p "$PGDATA"
    chown postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"
    su postgres -c "$PG_BIN/initdb -D '$PGDATA' --locale=C.UTF-8 --encoding=UTF8 --auth=trust"
fi
chown -R postgres:postgres "$PGDATA"

# --- Postgres: start if not running ----------------------------------------
if ! su postgres -c "$PG_BIN/pg_isready -h 127.0.0.1 -p '$PGPORT' -q" 2>/dev/null; then
    echo "[entrypoint] starting postgres on port $PGPORT"
    su postgres -c "$PG_BIN/pg_ctl -D '$PGDATA' -l '$PGDATA/server.log' -o '-p $PGPORT -k /var/run/postgresql -c listen_addresses=127.0.0.1' start"
fi
for _ in $(seq 1 30); do
    su postgres -c "$PG_BIN/pg_isready -h 127.0.0.1 -p '$PGPORT' -q" 2>/dev/null && break
    sleep 1
done
su postgres -c "$PG_BIN/pg_isready -h 127.0.0.1 -p '$PGPORT'"

# --- Database: create if missing -------------------------------------------
if ! su postgres -c "psql -h 127.0.0.1 -p '$PGPORT' -tAc \"SELECT 1 FROM pg_database WHERE datname='$PGDATABASE'\"" | grep -q 1; then
    echo "[entrypoint] creating database $PGDATABASE"
    su postgres -c "createdb -h 127.0.0.1 -p '$PGPORT' '$PGDATABASE'"
fi

# --- Redis: start if not running -------------------------------------------
if ! redis-cli -h 127.0.0.1 -p "$REDISPORT" ping >/dev/null 2>&1; then
    echo "[entrypoint] starting redis on port $REDISPORT"
    su redis -s /bin/sh -c "redis-server --port $REDISPORT --daemonize yes --save '' --appendonly no --protected-mode no --dir /var/lib/redis --logfile /var/log/redis/redis.log --pidfile /var/lib/redis/redis.pid"
fi
for _ in $(seq 1 30); do
    redis-cli -h 127.0.0.1 -p "$REDISPORT" ping >/dev/null 2>&1 && break
    sleep 1
done
redis-cli -h 127.0.0.1 -p "$REDISPORT" ping

# --- SearXNG: bundled web search (granian serves the Flask app) -----------
# Internal only (127.0.0.1:8080, not exposed). The limiter uses the
# Redis already running in this image (db 1, see settings-aio.yml).
# A random secret is generated per boot when SEARXNG_SECRET is unset
# (sessions only — nothing persists). If SearXNG fails to start,
# Pulse keeps serving local results and the unified query reports
# the web leg as "error"/"timeout" — the web leg must never take
# the API down. PULSE_SEARXNG_URL is set only when granian exists,
# so a missing install reports "unavailable" instead of "error".
export SEARXNG_SETTINGS_PATH="${SEARXNG_SETTINGS_PATH:-/etc/searxng/settings.yml}"
export SEARXNG_SECRET="${SEARXNG_SECRET:-$(cat /proc/sys/kernel/random/uuid)}"
if [ -x /opt/searxng-venv/bin/granian ]; then
    export PULSE_SEARXNG_URL="${PULSE_SEARXNG_URL:-http://127.0.0.1:8080}"
    echo "[entrypoint] starting searxng on 127.0.0.1:8080"
    ( /opt/searxng-venv/bin/granian --interface wsgi --host 127.0.0.1 --port 8080 --workers 1 "searx.webapp:app" >>/var/log/searxng.log 2>&1 ) &
    echo "[entrypoint] searxng starting in background (pid $!)"
    for _ in $(seq 1 60); do
        if curl -fsS "http://127.0.0.1:8080/healthz" >/dev/null 2>&1; then
            echo "[entrypoint] searxng is up"
            break
        fi
        sleep 1
    done
    curl -fsS "http://127.0.0.1:8080/healthz" >/dev/null 2>&1 || echo "[entrypoint] WARNING: searxng did not answer /healthz — web search will report unavailable until it does"
else
    echo "[entrypoint] WARNING: granian not found — web search unavailable"
fi

# --- Pulse worker: ingest feeds in the background ---------------------------
# A hosted deploy has no separate worker service (Render free has no free
# background workers), so the worker loop runs here alongside serve.
# It re-fetches the feeds every PULSE_INGEST_INTERVAL_S (default 300s).
# Delayed 45s so serve has finished its boot migrations first; if the
# worker ever dies, serve keeps answering from what's already stored.
( sleep 45; /usr/local/bin/pulse worker >>/var/log/pulse-worker.log 2>&1 ) &
echo "[entrypoint] worker starting in background (pid $!)"

# --- Pulse: migrates on boot, then serves ----------------------------------
cd /app
echo "[entrypoint] starting pulse on $PULSE_HOST:$PULSE_PORT (db $PGDATABASE on $PGPORT, redis on $REDISPORT)"
exec /usr/local/bin/pulse serve
