# Sando Pulse — all-in-one image

One image, everything inside: the Pulse server + Postgres 16 (vector
0.6.0, PostGIS 3.4.2, pg_trgm 1.6) + Redis 7. No separate database
setup, no compose stack. Built from the verified Roadmap 6 head
(255/255 tests).

## Run it (Dominic)

```sh
docker run -d --name pulse -p 9000:9000 \
  -v pulse-data:/var/lib/postgresql/data \
  sando-pulse:all-in-one-0.1.0
```

Then:

```sh
curl http://localhost:9000/v1/health
curl -X POST http://localhost:9000/v1/query \
  -H 'Content-Type: application/json' \
  -d '{"query":"fuel shortage in Monrovia"}'
```

First run takes ~10–20 s: Postgres initialises its data dir, creates
the `pulse` database, starts Redis, then Pulse migrates on boot and
serves. Later runs reuse the `pulse-data` volume — your documents
survive container restarts. Stop with `docker stop pulse`,
`docker start pulse` to bring it back.

### Set an API key (recommended before exposing the port)

```sh
docker run -d --name pulse -p 9000:9000 \
  -e PULSE_API_KEY='pick-a-long-random-key' \
  -v pulse-data:/var/lib/postgresql/data \
  sando-pulse:all-in-one-0.1.0
```

Without `PULSE_API_KEY` the API runs in open dev mode (no auth on
`/v1/query` and `/v1/ingest`) — fine on your own machine, not on a
public server.

### If ports are already taken

```sh
docker run -d --name pulse -p 19090:19090 \
  -e PULSE_PORT=19090 -e PULSE_PG_PORT=5433 -e PULSE_REDIS_PORT=6380 \
  -v pulse-data:/var/lib/postgresql/data \
  sando-pulse:all-in-one-0.1.0
```

### What runs inside

- Postgres 16 on 127.0.0.1:5432, database `pulse`, superuser
  `postgres`, trust auth on localhost only. The data dir is
  `/var/lib/postgresql/data` (the volume).
- Redis 7 on 127.0.0.1:6379, no persistence (`--save ''` — the
  cache rebuilds; the database is the source of truth).
- Pulse on 0.0.0.0:9000, working dir `/app`, migrations in
  `/app/migrations`. `pulse serve` migrates on boot.
- Pulse worker runs in the background inside the same container
  (started by the entrypoint, 45 s after boot), re-fetching the feeds
  every `PULSE_INGEST_INTERVAL_S` (default 300 s) — no separate worker
  service needed on a hosted deploy. Log: `/var/log/pulse-worker.log`.
- Healthcheck: `curl http://127.0.0.1:9000/v1/health` every 30 s.

Other Pulse commands work the same way, e.g. ingest worker:

```sh
docker exec pulse pulse worker --once
docker exec pulse pulse status
```

## Build it (from this repo)

```sh
docker/all-in-one/build.sh
```

That builds the Pulse binary on the host (Zig 0.17.1), vendors the
Ubuntu 24.04 `.deb`s (~210 MB, fetched from the Ubuntu archive at
candidate versions — mixing installed and candidate versions breaks
`dpkg`), then builds the image. The staged binary and `.deb`s live
under `docker/all-in-one/` and are **not** committed to git; see
`.gitignore`. Requires Zig 0.17.1 and an Ubuntu 24.04 apt setup on
the build host.

## Honest limits

- Local use. Postgres uses trust auth on localhost and the container
  runs as root (Postgres/Redis drop privileges internally). Do not
  publish port 9000 to the internet without `PULSE_API_KEY`.
- Redis has no persistence by design; the Postgres volume is the
  durable state. Back up with `docker exec pulse pulse backup`.
- The image is 1.45 GB (Ubuntu + Postgres + PostGIS/GDAL stack +
  Redis). First boot takes ~15 s on a small VM; after a stop/start,
  allow ~30 s for Postgres crash recovery before the API answers.
  The download is a ~1.4 GB tar — see the release notes for the link.
- The built-in HEALTHCHECK is stored in the image and runs on a real
  Docker host. (On this dev VM it stays `starting`: the VM blocks the
  exec the healthcheck needs, the same reason `podman exec` fails
  there. The `/v1/health` endpoint itself answers fine.)
- MinIO (raw-document object store) is NOT in this image — the
  compose stack's MinIO service is skipped; Pulse runs without it.
- Single instance: the in-process L1 cache and memindex live in the
  Pulse process. Scale-out is the compose stack, not this image.
