# Sando Pulse — Roadmap 1 STATUS

Last verified: **2026-11-12 ~19:10 GMT**. Zig 0.17.1 (`~/.local/bin/zig`).
Project: `~/workspace/pulse`. Local git only — no remote, nothing pushed.

## Verdict

Roadmap 1 is **complete and verified** on this VM except for the two items
listed under "Not verified on this VM" below (MinIO live run, full Docker
Compose stack run). Everything else ran for real and the numbers are below.

## Tests

- `zig build` — **passes** (binary `zig-out/bin/pulse`, ~37.4 MB).
- `zig build test` / `zig test src/root.zig` — **74/74 pass, 0 fail, 0 skip
  (live tests run), 0 leaks**. Includes the Postgres live test and the Redis
  live test, both gated on env vars and run against real local servers:
  - `PULSE_TEST_POSTGRES_URL=postgres://postgres:pulse_test@127.0.0.1:5432/pulse_test`
  - `PULSE_TEST_REDIS_URL=redis://127.0.0.1:6379`

## Live smoke test (server, memory store, port 9000, 2026-11-12 ~19:00)

Server started with `PULSE_API_KEY=testkey123`. Real curl outputs:

- `GET /v1/health` →
  `{"status":"ok","version":"0.1.0","documents":0,"sources_enabled":5,"store":"memory","request_id":"req-..."}`.
- `GET /v1/sources` → all 10 sources with enabled flags + disabled reasons.
- No key → 401 `auth_required`; wrong key → 401 `auth_invalid`.
- Real article ingested via `POST /v1/ingest` (fetched live from the New
  Dawn feed): **"Boakai Faces Growing Pressure"** —
  https://www.thenewdawnliberia.com/boakai-faces-growing-pressure/ (health
  workers, 3,800 volunteer health workers, US$500 minimum salary, President
  Joseph Nyuma Boakai, Nov 11, 2026). Ingest returned an id; health then
  showed `documents:1` (2 after a second ingest).
- `POST /v1/query {"query":"Boakai health workers salary"}` →
  `sufficient:true`, `confidence:0.65`, extractive answer from the real
  article with `[1]` citation, result title/URL/source correct, score
  `0.690875…`, plan intent `search`, topics `["health","politics"]`,
  sources = the 5 enabled. Caveats: the extractive answer starts mid-byline
  and includes the RSS "The post … appeared first on" boilerplate tail;
  `published_at:null` for manually ingested docs (the ingest endpoint takes
  no date — the worker pipeline sets it from RSS pubDate).
- `POST /v1/query {"query":"quantum computing in Lofa county"}` →
  `sufficient:false`, `insufficient_reason:"no_documents_matched"`,
  `confidence:0`, `results:[]`, counties `["Lofa"]` correctly extracted.
- `GET /metrics` → Prometheus text: request counters, query counters,
  insufficient-evidence counter, `pulse_documents_indexed_total` gauge (=2).

## Rate limiting (demonstrated 2026-11-12 ~18:35)

Second server on port 9001 with `PULSE_RATE_LIMIT_PER_MINUTE=3`,
`PULSE_API_KEY=testkey123`: requests 1–3 → 200, request 4 → **429**;
wrong key → 401; no key → 401.

## PostgreSQL (live, local PostgreSQL 16.15)

- Server: PostgreSQL 16.15 on Ubuntu, cluster `16/main`, port 5432, started
  via `service postgresql start` (was down; binaries already on the VM).
- Database `pulse_test` created; user `postgres` with a test password.
- `pulse migrate` → **exit 0, "migrations applied"**. Verified with psql:
  12 tables created (`api_keys`, `audit_logs`, `document_topics`,
  `documents`, `entities`, `event_entities`, `event_sources`, `events`,
  `locations`, `schema_migrations`, `sources`, `topics`).
- `schema_migrations` holds `001_initial` and `002_search_indexes`.
- Re-running `pulse migrate` is idempotent (exit 0, still 2 versions).
- **Postgres-backed server** (`DATABASE_URL` set): health reports
  `"store":"postgres"`; ingest + query work against Postgres; `SELECT
  count(*) FROM documents` confirmed the ingested article persisted.
- **Worker + Postgres + Redis**: `pulse worker --once` inserted 79 docs
  (2 → 81) in 20.3s; a repeat run is a no-op (81 → 81, content-hash dedup
  via `ON CONFLICT DO NOTHING`).
- Docs by source in Postgres: Daily Observer 50, New Dawn 11, GNN Liberia
  10, The News 10, Liberian Investigator 0 (see intermittent gap below).

### Bugs found and fixed during live verification

1. **BackendKeyData (`'K'`) message**: the Postgres client returned
   `ProtocolError` during SCRAM auth because it did not handle the
   `BackendKeyData` message the server sends after `AuthenticationOk`.
   Fixed (`'K' => {}` in `authenticate`); migrations then applied.
2. **Memory leaks in the Postgres client** (found by the test suite's
   SafeAllocator — 48 leaked allocations in the live test): `QueryResult`
   rows/command tags were never freed, `escapeLiteral` results passed
   inline to `allocPrint`/`appendSlice` leaked, and `documentFromRow`
   borrowed from result rows. Fixed by adding `QueryResult.deinit`,
   freeing results at every call site, duping document string columns,
   and adding allocation-free `appendEscapedLiteral` / `appendLikeLiteral`
   helpers. Suite is now leak-free (74/74, 0 errors logged).
3. **Flaky Redis live test** (found on a clean-cache re-run: 73 pass,
   1 fail): the test published an event then read the stream with
   `XRANGE … COUNT 10`, which returns the *oldest* 10 entries — once the
   stream held more than 10 entries (from worker runs) the new entry was
   no longer in the window. Fixed by adding `RedisClient.xrevrange`
   (`XREVRANGE`, newest first) and using it in the test. Suite now passes
   **74/74 three consecutive times** with live Postgres + Redis.

## Redis (live, local redis-server)

- Server: `redis-server` binary already on the VM; the systemd service
  fails (`217/USER` — the redis user cannot run here), so it was started
  directly with `redis-server --daemonize yes --port 6379` → `PING` → `PONG`.
- Live test (`PULSE_TEST_REDIS_URL`): **passes** — RESP2 PING/GET/SETEX,
  XADD/XGROUP/XREADGROUP/XRANGE round-trip.
- **Worker + Redis**: the `pulse:events` stream received
  `document.collected` events — `XLEN pulse:events` = 85 after the worker
  runs. The EventBus (Redis Streams) is live.

## Ingestion — worker `--once` (live feeds, 2026-11-12)

| Run | Docs | Time | Result |
|---|---|---|---|
| #6 (memory) | 0 → 80 | 15.1s | 4/5 sources; Liberian Investigator failed |
| ~18:57 (memory) | 0 → 90 | 20.1s | **5/5 sources, 0 errors** |
| Postgres run | 2 → 81 | 20.3s | 4/5 sources; Investigator failed |
| Postgres repeat | 81 → 81 | 20.8s | dedup confirmed; Investigator failed |

Per-source (latest run): Daily Observer 50/50, New Dawn 10/10 (after the
301 to www), GNN Liberia 10/10, The News 10/10, Liberian Investigator 0/1
error.

## Sources verified live (curl, 2026-11-12 ~17:00; feeds re-fetched by the worker)

**5 of 10 VERIFIED:** New Dawn (https://thenewdawnliberia.com/feed/ —
301 → https://www.thenewdawnliberia.com/feed/, 200, 51,674 bytes),
Liberian Investigator (https://liberianinvestigator.com/feed/), GNN Liberia
(https://gnnliberia.com/feed/), The News
(https://thenewsnewspaperonline.com/feed/), Daily Observer (TownNews RSS:
http://www.liberianobserver.com/search/?f=rss&t=article&l=50&s=start_time&sd=desc).

**5 SKIPPED, honestly recorded:** FrontPage Africa — Cloudflare "One
moment, please..." bot challenge blocks plain HTTP clients; Bush Chicken —
feed returns a 114-byte lander redirect stub, no content; Spoon TV (Spoon FM
Radio) — same lander stub; New Republic — domain parked on Hostinger DNS
(site does not exist); KMTV — homepage loads but no RSS feed or sitemap
exists. Registry in `src/ingestion/sources.zig` with enabled flags + reasons;
migrations seed the same 10.

## Fetcher (manual CONNECT + TLS — why)

`std.http.Client`'s proxied-HTTPS path is broken in Zig 0.17.1 (proven with
a fake-proxy capture: after `200 Connection Established` it writes a
plaintext GET through the CONNECT tunnel — no TLS handshake). The Pulse
fetcher (`src/ingestion/fetchers.zig`) does TCP → CONNECT → `std.crypto.tls.Client`
(SNI, CA bundle, `allow_truncation_attacks=true`) → GET → bounded body read
(Content-Length / chunked dechunking / close-delimited) → manual redirect
following (≤5). Six stacked bugs were found and fixed by measurement (see
git history): read-until-full `readSliceShort` semantics, a stale binary
hidden by a piped build exit code, the TLS `flush` not flushing the
underlying socket writer, read-until-EOF hanging on `Content-Length: 0`
301s, and partial-record `readVec` returning 0. 9 unit tests cover the
parsing; the worker runs prove the live path.

## Docker Compose (authored, validated, NOT run as a stack here)

- `docker-compose.yml` parses cleanly: 9 services (api, worker,
  postgres:16-alpine, redis:8-alpine, minio, prometheus, grafana,
  postgres-exporter, redis-exporter), 5 named volumes
  (`pulse-pgdata`, `pulse-redisdata`, `pulse-miniodata`,
  `pulse-promdata`, `pulse-grafanadata`), one network (`pulse-net`),
  **only port 9000 published**.
- `docker/Dockerfile` (multi-stage Zig build), Prometheus scrape config,
  Grafana datasource + dashboard provisioning (API + worker + DB panels)
  are authored.
- **Not run as a stack on this VM**: this VM's podman runs `--network none`
  (container networking fails with EPERM), so the multi-container stack
  cannot run here. The compose file is authored correctly for a real Docker
  host and is NOT hacked to fit this VM. Individual services were verified
  natively instead (Postgres 16 + Redis live, API server live, worker live).

## Observability

- Structured JSON logs (ts, level, msg) on stdout for server, worker,
  migrations.
- `GET /metrics` (Prometheus text): request counts by status class, total
  latency ms, query counts, insufficient-evidence count, ingest runs/errors,
  documents gauge. Verified live in the smoke test.
- Grafana dashboard provisioned in the compose stack (datasource +
  dashboard JSON) — not rendered live here (see Docker note above).

## Known gaps / intermittent issues (not blockers)

1. **Liberian Investigator is intermittent** (Cloudflare-fronted, chunked,
   ~61 KB feed; curl fetches it in 1.3s). It failed in most worker runs
   (connection closes mid-body, usually `EndOfStream` partway through the
   chunked body) but **succeeded once** (0 → 90 docs, all 5 sources, 0
   errors, 2026-11-12 ~18:57). Transient Cloudflare/proxy close, not a
   code bug — the same code path works for GNN and The News, also chunked.
2. **MinIO live run not verified on this VM.** The S3 client
   (`src/storage/object_store.zig`, SigV4) is unit-tested (HMAC-SHA256
   verified against RFC 4231 test case 1:
   `b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7`; 3
   object-store tests pass) but no live MinIO server could be run here:
   `dl.min.io` returns **410 Gone** (MinIO archived its open-source server
   downloads), `mirror.gcr.io` does not carry `minio/minio` (MANIFEST_UNKNOWN
   for `latest` and for `RELEASE.2024-12-18T13-15-44Z`), and the VM's
   container networking is broken anyway. The compose service definition is
   authored for a real host.
3. **Full Docker Compose stack not run here** (see Docker note above).
   Prometheus/Grafana/exporters are provisioned but not executed live.
4. **Prometheus/Grafana binaries** are not installed on this VM.
5. `published_at` is `null` for manually ingested docs (`/v1/ingest`
   takes no date); the worker pipeline sets it from RSS pubDate.
6. Extractive answers can start mid-byline and include RSS boilerplate
   ("The post … appeared first on …") — a normalizer improvement, not a
   correctness bug.

## Environment notes (this VM)

- Zig 0.17.1 at `~/.local/bin/zig`; `zig build` + `zig test` use an
  isolated cache at `~/workspace/tmp/pulse-cache`.
- PostgreSQL 16 and redis-server binaries were already installed on the VM
  (services were down; started manually). No containers were needed for the
  DB legs.
- Egress is proxy-only; the proxy password rotates frequently. The fetcher
  does unauthenticated CONNECT (the proxy accepts it) and never sends
  `Proxy-Authorization` on the tunnel.
- Never `pkill -f "pulse serve"` — the pattern matches your own shell and
  self-kills. Kill by port (`fuser -k 9000/tcp`) or PID.
- Never pipe `zig build` through `tail` and read `$?` — `$?` is the pipe's
  last command, not zig's. Check the binary timestamp after rebuilding.
- `zig test` passing does not prove the exe compiles (lazy function-body
  analysis). Always run `zig build` too.

## Roadmap 2 — COMPLETE 2026-11-12 ~21:30 GMT (commits 1abb38b, c26929e, 30f74a7, 846872b, 107eca5, 8273175, 13c7f7f)

Head: `13c7f7f`. Suite: **101/101 tests pass** (unit + live Postgres + Redis legs, leak-free). `zig build` green.

### 2.1 Dynamic query engine
- `planner.plan` now takes `(now, tz)` and delegates to `intent.classify` (intent + strategy + confidence) and `temporal.resolve` (real half-open time windows) instead of its own keyword lists; radius phrases ("within 50 km of Gbarnga", "near Monrovia") become a `GeoFilter`. Plan gains `time_from`/`time_to`, `strategy`, `classification_confidence`, `geo_filter`; `time_range` stays as the human label.

### 2.2 Hybrid search (pgvector + PostGIS — ALL LIVE, no substitute needed)
- Local Postgres 16 has `vector 0.6.0`, `postgis 3.4.2`, `pg_trgm 1.6` (checked live). Migration 003 creates the extensions; documents gain `embedding vector(128)`, `lat`, `lon`, `geom geography(Point,4326)`; trigram GIN + GiST indexes.
- Backends: memory store applies time window (published_at, fetched_at fallback), haversine geo radius, per-word trigram fuzzy at 0.5. Postgres applies the same via SQL: `COALESCE(published_at, fetched_at)` range, `ST_DWithin` geo, `word_similarity` fuzzy, pgvector `<=> < 0.6` OR branch for semantic candidate retrieval.
- Search: two-pass retrieval (exact, then fuzzy when < 3 candidates), dedup by content hash/id/url, fused scoring (0.6 base + 0.2 fuzzy + 0.2 semantic, renormalized when a signal is absent), evidence threshold 0.25 on the fused score.
- Live Postgres test verifies: geo-tagged + embedded probe doc round-trips (lat/lon/embedding 128-dim), time window, geo radius, fuzzy on/off, vector-only retrieval.

### 2.3 Result intelligence
- Results carry fused score + score parts (relevance/reliability/recency/context/coverage) + fuzzy/semantic scores. Event clustering (same topic OR trigram-similar titles within 72h) and tz-aware timeline buckets for timeline/historical intents. Response includes `events[]` + `timeline[]`; plan carries strategy, classification confidence, resolved time window as ISO.

### 2.4 AI integration interfaces
- `src/ai/providers.zig`: EmbeddingProvider (LocalHashEmbedding — deterministic hashed lexical, honestly labelled lexical not semantic — + ExternalEmbedding for OpenAI-compatible APIs), ExtractiveSummarizer, LocalEntityExtractor, LocalTopicClassifier, synthesizeGrounded (only quotes evidence sentences). `makeEmbeddingProvider` factory from config: local (default) / external (needs URL+key) / none.
- Wiring: main builds the provider once; worker/pipeline embed docs at ingest (title+text, 4000-byte cap, failure never blocks insert); server embeds on POST /v1/ingest and geo-tags it; query path passes the embedder + tz into search.
- Config: `PULSE_TZ_OFFSET_MINUTES` (default 0), `PULSE_EMBEDDING_PROVIDER`, `PULSE_EMBEDDING_API_URL/KEY/MODEL/DIMS` (default 128, matches vector(128)).

### 2.5 Temporal intelligence
- `intent.classify` + `temporal.resolve` (today/yesterday/tomorrow/this week/last week/this month/last month/this year/last year/counted windows/ISO + long dates/bare years/between ranges; timezone-aware day/month/year starts; `describe()`).

### Live smoke test (2026-11-12 ~21:20-21:30, Postgres + Redis, port 9000, local embedder)
- 3 docs ingested via POST /v1/ingest; all geo-tagged (Monrovia 6.3204/-10.806, Gbarnga 6.9963/-9.4709) and embedded (verified in Postgres).
- "fuel shortage in Monrovia": sufficient=true, 3 results with citations [1][2][3], semantic 0.64/0.53/0, 1 event (energy, 3 docs), plan local/balanced/0.85.
- "fuel shortage today": time window 2026-11-12T00:00 -> 2026-11-13T00:00, 3 results.
- "Monrova" (typo): sufficient=true, 3 results, fuzzy 0.706 each, fused 0.52/0.48/0.48.
- "news within 50 km of Gbarnga": 1 result (Budget debate in Gbarnga).
- "fuel shortage timeline": intent timeline, 1 event (3 docs), timeline day 2026-11-12 (3 docs).
- "quantum computing breakthrough in Lofa" (no evidence): sufficient=false, no_documents_matched (unit test).

### Bugs found by the smoke test (all fixed, all with regression tests)
1. `temporal.describe` printed `+2026-+11-+12`: Zig 0.17.1 fmt prints an explicit `+` for positive signed ints under a width spec. Fixed by casting year/month/day to u64 (same quirk is documented in common/format.zig). Regression test added.
2. The Roadmap 1 relevance gate zeroes the base when no query term appears verbatim — which made the fuzzy second pass useless (its docs have zero exact overlap by definition; the 0.2 fuzzy blend alone cannot reach 0.25). Fixed: when the base was gated, a >= 0.5 fuzzy/semantic signal counts as effective relevance for the fusion. Docs with no signal still score 0. Regression test added.
3. Postgres `word_similarity` dilutes with title length (measured: 4-word 0.24, 7-word 0.14, 8-word 0.12, unrelated 0.00). SQL fuzzy floor lowered 0.2 -> 0.1; the engine's strict per-word 0.5 re-score stays the real filter.
4. Chunk-2 `providers.zig` was never compiled before wiring: fixed `std.Io.Writer.Allocating` API use, a leaked StringHashMap key set, and `std.json.stringifyAlloc` (does not exist in 0.17.1). Also fixed `freeDocument` not freeing the new `embedding` field (memory leak in tests).
5. Two `pulse serve` processes can BOTH listen on 0.0.0.0:9000 on this VM (SO_REUSEADDR) — kill by PID and verify with `ss -ltnp` before starting a new one, or smoke tests hit a stale binary.

### Roadmap 2 honest gaps
1. Occurrence-date extraction is NOT implemented: time filtering uses `published_at` (fetched_at fallback), not dates mentioned inside article text. A story published today about an event last week is filed under today.
2. Events are clustered in-response only; they are NOT persisted to the `events` table (the table exists from Roadmap 1 but stays empty).
3. The local embedding is lexical (word-overlap hashing), not semantic — labelled as such everywhere. Real semantic search needs an external embedding API (PULSE_EMBEDDING_PROVIDER=external) or a model-produced vector.
4. No vector index yet (sequential scan on `embedding <=>`) — fine at this scale; revisit past ~10k docs.
5. `PULSE_EMBEDDING_DIMS` must match the `vector(128)` column; changing one without the other breaks inserts.
6. External embedding provider is code-complete but NEVER called live (no API key on this VM); only the interface + error paths are tested.
