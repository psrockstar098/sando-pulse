# Pulse operations runbook (Roadmap 5.4)

## Deploy

```sh
cp .env.example .env   # fill in POSTGRES_PASSWORD, PULSE_API_KEY, keys
docker compose up -d --build
```

- Migrations run automatically at API boot (`pulse serve` runs them
  before listening) and can also be run by hand:
  `docker compose exec api pulse migrate`.
- The API publishes only port 9000. Grafana (3000), Prometheus (9090)
  and the MinIO console (9001) are commented out in the compose file —
  uncomment them for local dev only, never for a public host.
- Run `./zig-out/bin/pulse audit` (or `docker compose exec api pulse
  audit`) before any production deploy. Any FAIL blocks the deploy.
- TLS termination is the reverse proxy's job (Pulse serves plain HTTP;
  the Zig 0.17.1 stdlib has no TLS server). Set
  `PULSE_BEHIND_TLS_PROXY=1` in production.

## Scale workers

One worker runs by default (`PULSE_WORKER_ID=worker-1`). For a second
worker (a separate Redis Streams consumer, so the two split realtime
work):

```sh
docker compose --profile scale up -d
```

## Backups

Automated backup (one-shot service, writes `backups/pulse-<UTC stamp>.sql`
into the `pulse-backups` volume, keeps the last 7 by default):

```sh
docker compose --profile backup run --rm backup
```

Manual backup on the host:

```sh
./zig-out/bin/pulse backup --out backups/pulse-$(date -u +%Y%m%dT%H%M%SZ).sql
```

The command prints bytes + SHA-256. Schedule it with cron on the host
(daily is the recommended minimum) and copy the files off the host —
a backup on the same disk as the database is not a backup.

## Restore / rollback

Restore **only into an empty database** (the dump is a plain pg_dump):

```sh
# 1. Stop the API and workers so nothing writes mid-restore.
docker compose stop api worker worker-2

# 2. Recreate the database empty.
docker compose exec postgres dropdb -U pulse pulse
docker compose exec postgres createdb -U pulse pulse

# 3. Restore, then migrate to the current schema.
docker compose exec -T postgres psql -U pulse -d pulse -v ON_ERROR_STOP=1 -f /backups/pulse-<stamp>.sql
docker compose exec api pulse migrate

# 4. Start everything again and verify.
docker compose up -d
curl -fsS http://127.0.0.1:9000/v1/health
```

Rollback of a bad deploy: the database is the only state that matters.
`git checkout <previous commit>`, rebuild, `docker compose up -d
--build`. Migrations are additive (new tables/columns only, no drops
in 001–011), so an older binary runs against a newer schema; if a
future migration ever drops something, restore from the pre-deploy
backup instead.

## Disaster recovery

1. New host, same repo + `.env` (secrets live outside git — keep a
   copy of `.env` in the operator's password manager).
2. `docker compose up -d` (creates an empty database).
3. Restore the latest backup with the procedure above.
4. Verify: `/v1/health` returns `status: ok`, `/v1/sources` lists the
   sources, and a known query returns `sufficient: true`.
5. Re-run `pulse audit` and confirm no FAIL.

## Health monitoring

- `/v1/health` — up/down + document count + sources enabled.
- `/metrics` — Prometheus text: request counts by class, latency
  total, query counts, cache hits/misses, ingest runs/errors,
  documents indexed, fan-out outcomes, auto-tuning adjustments +
  live knob values, process RSS.
- Auto-tuning (Roadmap 6.10): off by default (`PULSE_AUTOTUNE=1`
  enables). It moves only safe knobs within bounds (L1 TTL,
  fan-out timeout, worker concurrency) and logs every adjustment.
  Check `GET /v1/autotune`; restore the configured defaults with
  `POST /v1/admin/autotune/reset` (API key) or a restart.
- Prometheus scrapes the API, postgres-exporter, redis-exporter and
  node-exporter every 15s; rules live in
  `docker/prometheus/alerts.yml` (API down, 5xx rate, slow responses,
  ingest errors, cold cache, Redis memory, Postgres down).
- Alertmanager runs only with the alerts profile
  (`docker compose --profile alerts up -d`) and **ships with no real
  receiver** — configure one in
  `docker/alertmanager/alertmanager.yml` first (email/Slack/webhook).
- Grafana dashboards: `docker/grafana/dashboards/`.
- Logs: every service uses the json-file driver with rotation
  (10 MB × 3 files). Read them with `docker compose logs -f api`.

## Common incidents

| Symptom | Likely cause | First step |
| ------- | ------------ | ---------- |
| `/v1/health` 502 / connection refused | API container down | `docker compose ps`, `docker compose logs api` |
| Queries return `sufficient: false` on known topics | Worker not ingesting / feeds down | `docker compose logs worker`; check `/v1/sources` counts |
| `429 rate_limited` everywhere | Rate limit too low for traffic | Raise `PULSE_RATE_LIMIT_PER_*`, restart api |
| `429 quota_exceeded` for one consumer | That consumer's daily quota spent | `GET /v1/usage` to confirm; raise its quota in `PULSE_CONSUMERS` |
| Redis memory alert | Cache keys accumulating | Expected behaviour until TTL — maxmemory 256mb + allkeys-lru evicts; raise the limit if evictions hurt hit rate |
| `pulse audit` FAIL on `api_key` | No key configured (open dev mode) | Set `PULSE_API_KEY`, restart |
| `pulse audit` FAIL on `db_password` | `DATABASE_URL` still uses the example password `pulse` | Change `POSTGRES_PASSWORD` and `DATABASE_URL` |
| First query after a restart is slow | Cache cold / popular list empty | Expected on a fresh store — warming only covers queries already in `popular.json`; see below |

## Popular searches, persistence and warming (Roadmap 6.4)

- The server tracks every asked query (text + count only, no
  identity) in memory, bounded to `PULSE_POPULAR_MAX_TRACKED`
  distinct queries (default 1000; the lowest-count entry is evicted
  when full).
- The list is persisted to `PULSE_POPULAR_PATH` (default
  `popular.json`, relative to the API working directory) every
  `PULSE_POPULAR_SAVE_EVERY` records (default 100). A missing or
  corrupt file at boot just means no history yet — the server starts
  with an empty list, never a boot failure.
- At boot the server loads the list and warms the L1 + L2 caches with
  the top `PULSE_POPULAR_WARM_N` queries (default 10). The log lines
  `popular searches loaded` and `cache warmed` confirm it. Warming
  keys are the normalised (lowercased, whitespace-collapsed) query
  text, so a query typed with different casing computes fresh on its
  first ask and then caches under its own raw form.

## What runs here vs on a real host

This VM's podman runs `--network none`, so the compose stack cannot
run here at all: no container-to-container networking, no image pulls
from the registry in practice. Everything in this section is authored
for a real Docker host and validated only as far as this VM allows:
YAML parses, the binary builds, `zig build test` passes, and the API
itself was smoke-tested live on the host (see STATUS.md). The first
real `docker compose up` must happen on Dominic's machine or a
production host, with the checklist in `pulse audit` as the gate.
