# Pulse operations runbook (Roadmap 5.4)

## Live deployment (Render)

The production deployment is one Render Web Service, `sando-pulse`
(Frankfurt, Free plan), running the all-in-one image
`dominic908/sando-pulse:all-in-one-0.1.0` (digest
`sha256:e6e946bf…`, published 2026-11-17). Live since 2026-11-17:
https://sando-pulse.onrender.com.

- Environment: `PULSE_PORT=10000`, `PULSE_BEHIND_TLS_PROXY=1`,
  `PULSE_API_KEY` set (the key itself lives only in Render and with
  the operator — never in git, never in a file). Health check path
  `/v1/health`.
- First boot: the entrypoint initialises Postgres, starts Redis and
  the bundled SearXNG, serves Pulse, and starts the ingest worker
  in the background 45 s after boot. The worker ingested 80
  documents within ~6 minutes of the first boot.
- Free-tier facts: the service sleeps after 15 minutes idle — a
  keep-alive ping hits `/v1/health` every 10 minutes to keep it
  awake. A restart wipes the stored articles (no persistent disk);
  the worker re-fetches them from the feeds, so nothing is lost
  for good. Right after the first deploy the container restarted
  once and health answered 502 for ~5 minutes, then recovered on
  its own. Whole-container RSS is 341–401 MB, inside the 512 MB
  free limit with ~110 MB headroom.
- To redeploy: push to `origin main` (CI publishes a new
  `all-in-one-0.1.0` image), then redeploy the Render service from
  the dashboard (Manual Deploy), which pulls the new image. Verify
  after: `/v1/health` returns 200, `/v1/sources` lists the sources,
  and a unified query returns local + web results.
- Backups on Render free: there is no persistent disk, so a dump
  written inside the container does not survive a restart. The
  stored articles are re-fetchable from the feeds (nothing is lost
  for good), but there is no off-host backup on this plan — moving
  to a host with a real disk is the fix.

## Deploy (compose, full stack)

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
--build`. Migrations are additive (new tables/columns only — the only
DROP statements in the history are an index/constraint cleanup in
007–009, never data), so an older binary runs against a newer schema;
if a future migration ever drops something, restore from the pre-deploy
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
  live knob values, process RSS, circuit-breaker state/trips/skipped.
- Auto-tuning (Roadmap 6.10): off by default (`PULSE_AUTOTUNE=1`
  enables). It moves only safe knobs within bounds (L1 TTL,
  fan-out timeout, worker concurrency) and logs every adjustment.
  Check `GET /v1/autotune`; restore the configured defaults with
  `POST /v1/admin/autotune/reset` (API key) or a restart.
- Circuit breakers (Roadmap 6.11): watch `pulse_breaker_redis_state`
  / `pulse_breaker_embedding_state` (0 closed, 1 half-open, 2 open)
  and the `*_trips_total` / `*_skipped_total` counters. A breaker
  stuck open means the dependency is down, not the breaker — fix
  the dependency (Redis, or the external embedding provider); the
  breaker closes itself on the next successful trial call after the
  cooldown. Hot-reload safe settings with `POST /v1/admin/config`
  (API key): `l1_ttl_s`, `fanout_timeout_ms`, `reindex_interval_s`.
- Index maintenance (Roadmap 6.11): `pulse maintenance` runs a bare
  `ANALYZE` after retention; `pulse audit` reports an `indexes`
  check (index counts, never-scanned indexes, `documents` last
  ANALYZE). A WARN there means: run `pulse maintenance`, or review
  an index that has never been scanned.
- Benchmarking (Roadmap 6.12): `pulse loadtest` hammers a running
  server and reports p50/p95/p99/p99.9 for health + query, plus RSS
  and CPU when given the server pid:
  `pulse loadtest --url http://127.0.0.1:9000 --threads 1
  --requests 250 --query "fuel shortage in Monrovia" --distinct
  --server-pid <pid> --api-key <key>` (`--distinct` makes every
  query unique — the fast path; without it the run measures the
  instant path after warm-up. `--limit 1..20` sets
  `options.limit`). `pulse reindex` rebuilds the in-memory index
  from the store and reports docs added/terms (~89 s per 10k docs
  on the dev VM; the server rebuilds at boot the same way). Full
  method + latest numbers: `docs/PERFORMANCE.md`. Do not read
  absolute latencies off the dev VM as production numbers — the
  ~42 ms per-request floor there is the VM's `std.Io.Threaded`
  dispatch latency, not Pulse (same doc).
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
itself was smoke-tested live on the host (see STATUS.md). The
all-in-one image is the exception: it now runs live on Render
(verified 2026-11-17 — see "Live deployment" above), so the
single-image path is proven on a real host. The first real
`docker compose up` still has to happen on Dominic's machine or a
production host, with the checklist in `pulse audit` as the gate.

## Web search (SearXNG)

Full detail: `docs/WEBSEARCH.md`. The all-in-one image bundles
SearXNG — one `docker run` answers web searches with no extra
setup; on Render it is a single service, no second service needed.
SearXNG + Valkey also run behind the `websearch` compose profile
(`docker compose --profile websearch up -d`) as the dev alternative.
The API needs `PULSE_SEARXNG_URL` (e.g. `http://searxng:8080`) and
SearXNG needs `SEARXNG_SECRET` from `.env`. Without the URL, the
web leg of the unified `/v1/query` reports `unavailable` and `pulse
websearch` refuses to run. There is no separate public websearch
route: `GET /v1/websearch` was removed when the unified query
landed (2026-11-17) — one query does the job.

## Roadmap 7 operations

- **No new config vars.** Roadmap 7 adds no environment knobs:
  the forecast/stat/alert/report/social features run on the
  existing store + Redis. The alert stream and the briefing
  variants need no configuration.
- **Alert stream (`pulse:alerts`, consumer group `sando`).** The
  worker publishes one stream entry per merged breaking alert on
  every briefing refresh (fields: `kind`, `title`, `event_ids`,
  `sources`, `doc_count`, `importance`, `ts`). Sando subscribes
  with `XREADGROUP GROUP sando <consumer> STREAMS pulse:alerts >`.
  `pulse alerts` reads the stream back newest-first for operators
  (empty stream and no-Redis both report plainly). A publish
  failure never fails the briefing refresh — it logs and the
  endpoint keeps computing live.
- **Report schedules.** The worker refreshes only the default
  daily-general briefing, on `PULSE_PRECOMPUTE_INTERVAL_S`
  (default 3600 s), and caches it in Redis. Weekly, political,
  economic and county variants are computed live per request and
  never cached — no schedule, no stale variant. `pulse briefing
  [--scope weekly] [--kind political|economic] [--county <name>]`
  renders any variant from the live store for operators.
- **Seed updates.** `pulse seed` is idempotent (upserts); run it
  after pulling a seed change. Current counts: locations 166,
  facilities 47, statistics 5. The seed test pins the counts, so
  a count change without a test update fails the suite on purpose.
