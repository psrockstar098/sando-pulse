# Sando Pulse — Roadmap 1: Foundation & Infrastructure

A Liberia-first intelligence / search engine backend. Zig 0.17.1 only,
REST only (`std.http` — no external HTTP framework, no GraphQL, no gRPC,
no WebSockets), real data only. Ask a question, get a cited answer about
Liberia in seconds — or an honest "insufficient evidence" when the indexed
documents do not support an answer.

## Quick start (local dev)

```sh
zig build            # builds zig-out/bin/pulse
zig build test       # runs the full test suite

# Serve with the in-memory store (dev default):
PULSE_API_KEY=testkey123 ./zig-out/bin/pulse serve

# Serve with PostgreSQL + Redis:
DATABASE_URL=postgres://postgres:pulse_test@127.0.0.1:5432/pulse_test \
REDIS_URL=redis://127.0.0.1:6379 \
PULSE_API_KEY=testkey123 ./zig-out/bin/pulse serve

# Ingest once (fetches the 5 enabled Liberian RSS feeds):
./zig-out/bin/pulse worker --once

# Apply database migrations:
DATABASE_URL=... ./zig-out/bin/pulse migrate

# Generate an API key:
./zig-out/bin/pulse keygen
```

## Full stack (real Docker host)

```sh
cp .env.example .env   # fill in secrets; .env is gitignored, never committed
docker compose up --build
```

The compose stack (see `docker-compose.yml`) runs: api, worker, postgres:16,
redis:8, minio, prometheus, grafana, postgres-exporter, redis-exporter — on
one network (`pulse-net`), named volumes for all data, and **only port 9000
published**. The API container runs migrations on boot.

## Configuration (env vars at runtime only — never in files)

| Variable | Default | Purpose |
|---|---|---|
| `PULSE_HOST` | `0.0.0.0` | API listen address |
| `PULSE_PORT` | `9000` | API listen port |
| `PULSE_API_KEY` | — (open dev mode + boot warning) | Bearer API key for `/v1/query` and `/v1/ingest` |
| `DATABASE_URL` | — (memory store) | `postgres://user:pass@host:port/db`; enables PostgresStore |
| `REDIS_URL` | — (no event bus) | `redis://host:port`; enables the Redis Streams event bus |
| `MINIO_ENDPOINT` / `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` / `MINIO_BUCKET` | `pulse-raw` bucket | S3-compatible raw store (MinIO) |
| `PULSE_INGEST_INTERVAL_S` | `300` | Worker ingest interval |
| `PULSE_RATE_LIMIT_PER_MINUTE` / `PULSE_RATE_LIMIT_PER_DAY` | `100` / `10000` | Per-key rate limits |
| `PULSE_LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |
| `PULSE_POPULAR_MAX_TRACKED` | `1000` | Distinct queries tracked for `GET /v1/popular` (Roadmap 6.4) |
| `PULSE_POPULAR_PATH` | `popular.json` | Where the popular list is persisted (Roadmap 6.4) |
| `PULSE_POPULAR_SAVE_EVERY` | `100` | Persist the popular list every N records (Roadmap 6.4) |
| `PULSE_POPULAR_WARM_N` | `10` | Top popular queries warmed into L1/L2 at boot (Roadmap 6.4) |

## API

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/v1/health` | no | `{"status":"ok","version","documents","sources_enabled","store"}` |
| GET | `/v1/sources` | no | All 10 sources with enabled flags and disabled reasons |
| GET | `/v1/trends` | no | Geez + geo trends; carries `computed_at` + `stale` (Roadmap 6.4) |
| GET | `/v1/briefing` | no | Precomputed briefing; carries `cached` + `stale` (Roadmap 6.4) |
| GET | `/v1/popular` | no | Most-asked queries with counts (Roadmap 6.4) |
| GET | `/metrics` | no | Prometheus text metrics |
| POST | `/v1/query` | Bearer key | `{"query": "..."}` → cited answer or insufficient-evidence |
| POST | `/v1/ingest` | Bearer key | Manual document ingest `{"title","url","source_id","text"}` |

Every response carries a `request_id` (`req-{hex nanos}`). Rate limits:
100/min + 10,000/day per key (429 when exceeded). Auth failures are 401
(`auth_required` / `auth_invalid`).

### Query response

```json
{
  "query": "Boakai health workers salary",
  "answer": "... [1]",
  "sufficient": true,
  "insufficient_reason": null,
  "confidence": 0.65,
  "results": [{ "title": "...", "url": "...", "source": {"name": "New Dawn"}, "score": 0.69 }],
  "query_plan": { "intent": "search", "topics": ["health","politics"], "counties": [], "organizations": [], "sources": ["daily-observer","new-dawn","liberian-investigator","gnn-liberia","the-news"] },
  "meta": { "request_id": "...", "results_count": 1, "sources_checked": 5 }
}
```

**Hard rule:** no answer is better than a wrong answer. When no indexed
document clears the evidence threshold, the API returns
`"sufficient": false`, `"answer": null`, `"insufficient_reason":
"no_documents_matched"` and `confidence: 0`. Answers are extractive only —
built from indexed documents, never invented.

## Query engine

- **Planner** (`src/engine/planner.zig`): Parse → Enrich → Choose → Execute
  → Synthesize. Extracts Liberian entities: all 15 counties, major
  cities/towns, organizations (LPRC, CBL, Ministry of Commerce, NEC, LRA,
  …), topics (energy, economy, health, politics, society, culture).
- **Ranking** (`src/engine/ranking.zig`): score = 0.35·relevance +
  0.22·reliability + 0.18·recency + 0.15·context + 0.10·coverage; minimum
  evidence 0.25; a document with zero query-term overlap scores 0.
  Confidence = 0.40·agreement + 0.30·consensus + 0.30·freshness.
- **Search** (`src/engine/search.zig`): lexical search over the document
  store (in-memory or PostgreSQL FTS with tsvector + GIN indexes).

## Sources (10 Liberian outlets)

Verified live 2026-11-12 (see STATUS.md for the full evidence):

| Source | Feed | Status |
|---|---|---|
| New Dawn | thenewdawnliberia.com/feed/ | ✅ verified |
| Liberian Investigator | liberianinvestigator.com/feed/ | ✅ verified (intermittent Cloudflare close) |
| GNN Liberia | gnnliberia.com/feed/ | ✅ verified |
| The News | thenewsnewspaperonline.com/feed/ | ✅ verified |
| Daily Observer | liberianobserver.com (TownNews RSS) | ✅ verified |
| FrontPage Africa | frontpageafricaonline.com/feed/ | ❌ Cloudflare bot challenge blocks non-browser clients |
| Bush Chicken | — | ❌ feed returns a lander redirect stub, no content |
| Spoon TV (Spoon FM) | — | ❌ same lander stub |
| New Republic | — | ❌ domain parked on Hostinger DNS |
| KMTV | — | ❌ homepage loads, no RSS feed or sitemap |

## Layout

```
src/main.zig            CLI: serve | worker [--once] | migrate | status | keygen
src/api/                server.zig (std.http), auth.zig, ratelimit.zig, metrics.zig, query.zig
src/engine/             planner.zig, entities.zig, ranking.zig, search.zig
src/ingestion/          fetchers.zig (manual CONNECT+TLS fetcher), rss.zig,
                        normalizer.zig, pipeline.zig, sources.zig
src/storage/            repository.zig (vtable), memory.zig, postgres.zig,
                        redis.zig (RESP2 + Streams), object_store.zig (S3/MinIO SigV4)
src/workers/worker.zig  ingest loop
src/common/             types.zig, errors.zig, logging.zig, time.zig, format.zig
src/config/config.zig   env-based config
migrations/             001_initial.sql, 002_search_indexes.sql
docker/                 Dockerfile, prometheus/, grafana/ (datasource + dashboard)
docker-compose.yml      api, worker, postgres, redis, minio, prometheus, grafana, exporters
docs/INTERFACES.md      internal module interfaces
```

## Design notes (Zig 0.17.1)

- Networking is the new `std.Io` API (`std.Io.Threaded`, `IpAddress.listen`,
  `stream.reader`/`writer`). Time comes from `std.Io.Clock.real`
  (`std.time` has no wall-clock functions). Entry point is
  `pub fn main(init: std.process.Init)`.
- `std.http.Client`'s proxied-HTTPS path is broken in 0.17.1 (it writes a
  plaintext GET through the CONNECT tunnel — no TLS). The fetcher does
  CONNECT + TLS itself (`std.crypto.tls.Client`).
- `std.Thread.Mutex` does not exist in 0.17.1; Pulse is single-threaded in
  Phase 1. `std.http.Server` is the only HTTP framework (Dominic's order:
  "No use zig http" — std.http only).
- Zig lazily analyzes function bodies: `zig test` passing does not prove the
  exe compiles. Always run `zig build` and check the binary timestamp.

## Tests

`zig build test` — 74 tests (planner, ranking, index, RSS parsing, fetcher
parsing, auth, rate limiting, metrics, JSON, Postgres wire protocol, Redis
RESP2, S3 signing). The Postgres and Redis live tests are gated on
`PULSE_TEST_POSTGRES_URL` / `PULSE_TEST_REDIS_URL` and skip without servers.
