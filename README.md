# Sando Pulse — Liberia-first intelligence & search engine

A Liberia-first intelligence / search engine backend. Zig 0.17.1 only,
REST only (`std.http` — no external HTTP framework, no GraphQL, no gRPC,
no WebSockets), real data only. Ask a question, get a cited answer about
Liberia in seconds — or an honest "insufficient evidence" when the indexed
documents do not support an answer.

**Live:** https://sando-pulse.onrender.com — one smart `POST /v1/query`
fans out to the local Liberia index, live web search (SearXNG, bundled
in the image), and Facebook/social posts when configured, and returns
one ranked, cited answer. See "Live API (Render)" below and
`docs/WEBSEARCH.md`. Tests: **341/341 passing** (`zig build test`),
CI green on `50947a4`.

## Live API (Render)

The production deployment is a single Render Web Service
(`sando-pulse`, Frankfurt, Free plan) running the all-in-one image
`dominic908/sando-pulse:all-in-one-0.1.0` (digest
`sha256:e6e946bf…`, published 2026-11-17). Environment:
`PULSE_PORT=10000`, `PULSE_BEHIND_TLS_PROXY=1`, `PULSE_API_KEY` set;
health check `/v1/health`. Live since 2026-11-17, verified the same
day: health 200 with 9 sources enabled, the worker ingested 80
documents within ~6 minutes of first boot, and a unified
`"Liberia news"` query returned 10 results — real local articles
plus real web results via Brave (BBC Liberia, Al Jazeera Liberia).

```sh
curl https://sando-pulse.onrender.com/v1/health
curl -X POST https://sando-pulse.onrender.com/v1/query \
  -H "Authorization: Bearer <PULSE_API_KEY>" \
  -H 'Content-Type: application/json' \
  -d '{"query": "Liberia news"}'
```

Free-tier facts, honestly: the service sleeps after 15 minutes idle
(a keep-alive ping hits `/v1/health` every 10 minutes to keep it
awake); a restart wipes the stored articles (no persistent disk),
but the worker re-fetches them from the feeds, so nothing is lost
for good. Right after the first deploy the container restarted once
and health answered 502 for ~5 minutes, then recovered on its own.
The whole container measures 341–401 MB RSS, inside the 512 MB
free limit with ~110 MB headroom (see `docs/PERFORMANCE.md`).

## All-in-one Docker image (local run)

```sh
docker run -d --name pulse -p 9000:9000 \
  -v pulse-data:/var/lib/postgresql/data \
  dominic908/sando-pulse:all-in-one-0.1.0
```

One image, everything inside: Pulse + Postgres 16 + Redis 7 +
SearXNG (web search, out of the box — no second service). The
entrypoint initialises Postgres, starts Redis and SearXNG (granian,
6 engines), then serves Pulse on port 9000 and starts the ingest
worker in the background 45 s after boot. The `pulse-data` volume
keeps documents across restarts on your own machine (on Render
free there is no volume — see the live section above). Set
`PULSE_API_KEY` before exposing the port.

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

# Ingest once (fetches the 9 enabled Liberian RSS feeds):
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
published**. The API container runs migrations on boot. This is the
full-stack route for a real Docker host; the single-image deploy route
is the all-in-one image above, and the live deployment on Render uses
it. SearXNG + Valkey run behind the `websearch` compose profile as
the dev alternative to the bundled SearXNG (`docs/WEBSEARCH.md`).

## Configuration (env vars at runtime only — never in files)

| Variable | Default | Purpose |
|---|---|---|
| `PULSE_HOST` | `0.0.0.0` | API listen address |
| `PULSE_PORT` | `9000` | API listen port |
| `PULSE_API_KEY` | — (open dev mode + boot warning) | Bearer API key for `/v1/query` |
| `DATABASE_URL` | — (memory store) | `postgres://user:pass@host:port/db`; enables PostgresStore |
| `REDIS_URL` | — (no event bus) | `redis://host:port`; enables the Redis Streams event bus |
| `MINIO_ENDPOINT` / `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` / `MINIO_BUCKET` | `pulse-raw` bucket | S3-compatible raw store (MinIO) |
| `PULSE_INGEST_INTERVAL_S` | `300` | Worker ingest interval |
| `PULSE_SEARXNG_URL` | — (unset → web leg `unavailable`) | SearXNG base URL, e.g. `http://searxng:8080`; the all-in-one entrypoint exports `http://127.0.0.1:8080` when its bundled SearXNG starts (docs/WEBSEARCH.md) |
| `PULSE_WEB_TIMEOUT_MS` | `1500` (min 50) | How long the unified query waits for the web (SearXNG) leg before answering with what it has |
| `PULSE_FACEBOOK_ACCESS_TOKEN` | — (unset → social leg `not_configured`) | Facebook Page token (from a long-lived user token via `GET /me/accounts`); without it the worker collects no posts and the social leg reports `not_configured` |
| `PULSE_BEHIND_TLS_PROXY` | `0` | Set to `1` in production behind a TLS-terminating proxy (Render, or a reverse proxy); `pulse audit` warns while it is unset |
| `SEARXNG_SECRET` | generated per boot (all-in-one) | SearXNG secret key (`server.secret_key`); set it yourself with the `websearch` compose profile |
| `PULSE_RATE_LIMIT_PER_MINUTE` / `PULSE_RATE_LIMIT_PER_DAY` | `100` / `10000` | Per-key rate limits |
| `PULSE_LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |
| `PULSE_POPULAR_MAX_TRACKED` | `1000` | Distinct queries tracked internally for cache warming (Roadmap 6.4) |
| `PULSE_POPULAR_PATH` | `popular.json` | Where the popular list is persisted (Roadmap 6.4) |
| `PULSE_POPULAR_SAVE_EVERY` | `100` | Persist the popular list every N records (Roadmap 6.4) |
| `PULSE_POPULAR_WARM_N` | `10` | Top popular queries warmed into L1/L2 at boot (Roadmap 6.4) |
| `PULSE_AUTOTUNE` | `0` (off) | `1` enables bounded auto-tuning of safe knobs (Roadmap 6.10) |
| `PULSE_BREAKER_EMBED_FAILURES` | `5` | Consecutive external-embedder failures that trip its breaker open (Roadmap 6.11) |
| `PULSE_BREAKER_EMBED_COOLDOWN_S` | `60` | Seconds before a trial embed call is allowed after the breaker trips (Roadmap 6.11) |
| `PULSE_BREAKER_REDIS_FAILURES` | `5` | Consecutive Redis errors that trip the L2 breaker open (Roadmap 6.11) |
| `PULSE_BREAKER_REDIS_COOLDOWN_S` | `60` | Seconds before a trial L2 call is allowed after the breaker trips (Roadmap 6.11) |

## API

Three routes. Nothing else.

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/v1/health` | no | `{"status":"ok","version","documents","sources_enabled","store"}` |
| POST | `/v1/query` | Bearer <redacted> | `{"query": "..."}` → cited answer or insufficient-evidence; the ONE search surface — it fans out in parallel to the local index + web (SearXNG, bundled in the all-in-one image) + Facebook/social when configured, deduplicates by URL, and each result carries `kind` (`local` / `social`) with a top-level `unified` object citing each leg's status (docs/WEBSEARCH.md). The debug path is the `pulse websearch` CLI. |
| GET | `/v1/webhooks/facebook` | no | Meta subscription handshake (verify token, not API key) |
| POST | `/v1/webhooks/facebook` | no | Facebook webhook receiver (HMAC signature is the auth) |

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
  "path": "fast",
  "latency_ms": 85.17,
  "routing_reason": "default_fast",
  "results": [{ "title": "...", "url": "...", "kind": "local", "source": {"name": "New Dawn"}, "score": 0.69 }],
  "unified": {
    "web": [{ "title": "...", "summary": "...", "url": "https://…", "engine": "brave",
              "source": {"name": "brave", "url": "https://…"} }],
    "web_complete": true,
    "sources": [
      { "name": "local",    "status": "ok",             "results": 3, "detail": null },
      { "name": "web",      "status": "ok",             "results": 2, "detail": null },
      { "name": "facebook", "status": "not_configured", "results": 0, "detail": "Facebook is not configured — set PULSE_FACEBOOK_ACCESS_TOKEN" }
    ]
  },
  "query_plan": { "intent": "search", "topics": ["health","politics"], "counties": [], "organizations": [], "sources": ["daily-observer","new-dawn","liberian-investigator","gnn-liberia","the-news"] },
  "meta": { "request_id": "...", "results_count": 1, "sources_checked": 5 }
}
```

`path` is the execution path (`instant` / `fast` / `deep`),
`latency_ms` the measured server-side latency, `routing_reason`
why the router chose it. `options.limit` (1–20, default 10)
controls how many results come back. `kind` on each result is
`"local"` for RSS documents and `"social"` for Facebook posts
(source_id starting `facebook:`). `unified.web` holds the web
results (SearXNG's order, deduplicated against local results by
normalized URL); `unified.sources` is honest about each leg —
`web` is `ok` / `unavailable` / `timeout` / `error`, `facebook`
is `configured` / `not_configured` — and `web_complete` says
whether the web leg finished before the answer was sent. The
web leg waits at most `PULSE_WEB_TIMEOUT_MS` (default 1500 ms);
a slow web leg never delays the answer. Stat answers do not fan
out to the web. Full detail: `docs/WEBSEARCH.md`.

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

## Performance (Roadmap 6)

Three execution paths, chosen per query by the router
(`src/engine/router.zig`):

| Path | When | What it does |
|---|---|---|
| `instant` | L1 or L2 cache hit | Serves the stored body with only the request id / path / latency spliced in — no store work |
| `fast` | Everything else (default) | Memindex shortlist (top 50 candidates) resolved via `getDocument`; fewer than 3 usable candidates falls back to the store search |
| `deep` | Research / compare / historical intents, `strategy: deep`, or no lexical terms | Whole candidate set + semantic/correlation + fuzzy second pass |

Cache layers: L1 in-process (bounded 512 entries / 8 MiB, per-entry
TTL, consumer-scoped keys, tag invalidation on ingest) in front of
L2 Redis (query cache, TTL `PULSE_QUERY_CACHE_TTL_S`). The
in-memory inverted index (`src/engine/memindex.zig`) is built from
the store at boot and on epoch change (rebuild interval
`PULSE_REINDEX_INTERVAL_S`, default 3600 s); `pulse reindex`
rebuilds it on demand. Enrichment (locations + statistics) fans
out in parallel when `PULSE_PARALLEL_QUERY=1` and the store is
Postgres. See `docs/PERFORMANCE.md` for the architecture, the
auto-tuning knobs + bounds, and the scaling guide.

**Measured latencies** (client-measured, `pulse loadtest`,
threads=1 — full tables in `docs/PERFORMANCE.md`):

| Store | instant p50 | fast p50 | deep p50 |
|---|---|---|---|
| 3–5 docs | 42.7 ms | 126.9 ms | 127.1 ms |
| 10,005 docs | 42.8 ms | 189.1 ms | 151.7 ms |

The spec's 5 ms hot path is a **target, not a result**: the dev
VM measures a ~42 ms floor on every request (server CPU <1 ms per
request — the cost is `std.Io.Threaded` socket-op dispatch latency
under this VM's CPU throttle, not Pulse code). Do not quote VM
numbers as production numbers; re-measure on a real host.

**How to benchmark:**

```sh
# Start the server, note its pid, then:
./zig-out/bin/pulse loadtest --url http://127.0.0.1:9000 \
  --threads 1 --requests 250 --query "fuel shortage in Monrovia" \
  --distinct --server-pid <pid> --api-key <key>
# --distinct: every query unique (fast path). Without it: the instant
# path after warm-up. --limit 1..20 sets options.limit.
# Reports p50/p95/p99/p99.9, RSS before/after, CPU per 1k queries.
```

**What the VM can and cannot prove:** it can prove correctness
(0 errors at 50-way concurrency), the memory plateau (RSS flat
over 1,250 sustained queries), the breaker trip/close cycle, and
the 10k-doc scale point (index build ~89 s, idle RSS 45.2 MiB).
It cannot prove the 5 ms hot path, 1K/10K concurrency, or the
1M/10M+ indexed-record milestones — those need a real host (and,
for concurrency, the threaded accept loop recorded as a gap in
`docs/PERFORMANCE.md`).

## New in Roadmap 7

- **Stat answers** (`POST /v1/query` with a "how many …" or "population of …" question): answered from the seeded knowledge store only — facility counts and census populations with source + verification date. A question about a place or facility Pulse doesn't know returns `sufficient: false` with an honest reason, never a guessed number.
- **Breaking alerts** (`pulse alerts`): typed incidents (accident, protest, road closure, emergency, announcement, community event, unknown), merged by kind + title similarity, every source cited. Published to the `pulse:alerts` Redis stream (consumer group `sando`) for Sando to subscribe to.
- **Report variants** (`pulse briefing --scope weekly --kind political --county Lofa`): weekly scope, political/economic kinds, and county filters (a Monrovia story counts for Montserrado — cities resolve to their county). Variants are computed live, never cached; unknown scope/kind/county is a 400. The briefing carries a `social_note` that is honestly empty until an authorized social source connects.
- **Knowledge coverage** (`pulse seed`, 166 locations / 47 facilities / 5 statistics): Grand Kru's 2008 district populations filled from the Wikipedia Grand Kru County page (see seed/liberia.zig).
- **Social ingestion — gated**: the registry is fed only by authorized connector data. The Facebook connector is built (Graph API + webhooks, authorized pages only, never scraped or faked) and activates when `PULSE_FACEBOOK_ACCESS_TOKEN` is set — a Page token from a long-lived user token via `GET /me/accounts`. Until then the unified query's `facebook` leg reports `not_configured`. No scrapers, no faked posts.
- **Semantic search — blocked**: the external embedding provider exists but has no API key and is never called live. Deep queries use the lexical local embedder.

## Trust & Intelligence Engine — removed

The Trust Engine's route surface (source profiles, monitor, evidence, scores, rankings, history, actions, decision core, predictions, anomalies, risk) was removed on 2026-11-18 when the API was cut to three routes. The code is gone; the history is in git. What remains: the 12-source registry, per-source health tracking (migration 014, `source_health.last_new_at`, stamped by the worker), and the seeded county/location data. Credibility scoring and claim assessment no longer exist — `/v1/query` answers from evidence only, and says `sufficient: false` when it has none.


## Sources (12 Liberian outlets)

Verified live 2026-11-13 (see STATUS.md for the full evidence):

| Source | Feed | Status |
|---|---|---|
| New Dawn | thenewdawnliberia.com/feed/ | ✅ verified |
| Liberian Investigator | liberianinvestigator.com/feed/ | ✅ verified |
| GNN Liberia | gnnliberia.com/feed/ | ✅ verified |
| The News | thenewsnewspaperonline.com/feed/ | ✅ verified |
| Daily Observer | liberianobserver.com (TownNews RSS) | ✅ verified |
| FrontPage Africa | frontpageafricaonline.com/feed/ | ✅ verified (was blocked — fetcher now sends a browser User-Agent) |
| KMTV | mykmtvnews.com/feed/ | ✅ verified (new home — old domain taken over by a betting site) |
| The Analyst | analystliberiaonline.com/feed/ | ✅ verified (new source) |
| Local Voices Liberia | localvoicesliberia.com/feed/ | ✅ verified (new source) |
| Bush Chicken | — | ❌ domain parked, site gone (verified 2026-11-13) |
| Spoon TV (Spoon FM) | — | ❌ closed by court order July 2023; no website feed (verified 2026-11-13) |
| New Republic | — | ❌ domain parked (verified 2026-11-13) |

## Layout

```
src/main.zig            CLI: serve | worker [--once] | migrate | status | keygen
src/api/                server.zig (std.http), auth.zig, ratelimit.zig, metrics.zig, query.zig
src/engine/             planner.zig, entities.zig, ranking.zig, search.zig
src/search/             searxng.zig (SearXNG client, std.http only), unified.zig (one-query fan-out)
src/ingestion/          fetchers.zig (manual CONNECT+TLS fetcher), rss.zig,
                        normalizer.zig, pipeline.zig, sources.zig, connectors/ (facebook)
src/sando/client.zig    PulseClient pattern for Sando (std.http only)
src/storage/            repository.zig (vtable), memory.zig, postgres.zig,
                        redis.zig (RESP2 + Streams), object_store.zig (S3/MinIO SigV4)
src/workers/worker.zig  ingest loop
src/common/             types.zig, errors.zig, logging.zig, time.zig, format.zig
src/config/config.zig   env-based config
migrations/             001–015 (initial schema, search indexes, audit log, source
                        profiles, monitor freshness, New Dawn feed fix)
docker/                 Dockerfile, all-in-one/ (single-image deploy incl. SearXNG),
                        prometheus/, grafana/ (datasource + dashboard), searxng/
docker-compose.yml      api, worker, postgres, redis, minio, prometheus, grafana, exporters
                        (+ lb + worker-2 under the `scale` profile, searxng +
                        searxng-valkey under the `websearch` profile)
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

`zig build test` — 341 tests (planner, ranking, index, RSS parsing, fetcher
parsing, auth, rate limiting, metrics, JSON, Postgres wire protocol, Redis
RESP2, S3 signing, SearXNG client + unified fan-out, Trust & Intelligence
Engine Phases 1–8). CI (`ci` + `docker-publish`) is green on `50947a4`.
The Postgres and Redis live tests are gated on
`PULSE_TEST_POSTGRES_URL` / `PULSE_TEST_REDIS_URL` and skip without servers.
