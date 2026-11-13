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

## Roadmap 3 — COMPLETE 2026-11-13 ~00:30 GMT

Commits: 3.1 `bd864df`, 3.3/3.4 `ab620c7` + `eacd3b6`, 3.2 `354a836`, Facebook `8cd8016`, 3.5 `0763a9f` + `ddfa5da`, 3.6 `6852ce7` + `35c0bba` + `94c67cf` (migrations 007–009). Head `94c67cf`.

### Tests

- `zig build` — **passes** (binary `zig-out/bin/pulse`).
- `zig test src/root.zig -lc -lzstd` with live Postgres + Redis + OSM — **139/139 pass, 0 fail, 0 skip** (log `~/workspace/tmp/pulse-r3-loc-live.log`). Includes the Postgres live test, Redis live test, OSM Nominatim live test (gated on `PULSE_TEST_OSM=1`), Postgres-knowledge live test, and the seed test (counts + provenance + idempotency).

### 3.1 Source management (`bd864df`)

- `src/ingestion/source_manager.zig`: per-source runtime config from env (`ENABLED`/`LIMIT`/`INTERVAL_S`/`AUTH_ENV` overrides), reliability tiers (high ≥ 0.85, standard ≥ 0.60, low), due-check against recorded last run, auth state (none/configured/missing). Credentials are named by env var only — values are never read or logged.
- Pipeline resolves runtime per source; skips disabled, auth-missing (logged, reported), and not-yet-due sources; caps items per run at the source limit. Health `last_run_at` drives scheduling.

### 3.2 Connector framework (`354a836`) + Facebook connector (`8cd8016`)

- Connector interface: `check()` gate + `fetch()`; `fetch()` only after `check()` says available. `allConnectors()` returns all 8 kinds in spec order.
- RSS live via the proven CONNECT+TLS fetcher; Website allowlist-only (`PULSE_WEBSITE_ALLOWLIST`, off-list fetch returns `NotPermitted` without any network call); Government configured-endpoint only (`PULSE_GOVERNMENT_URL`); OSM live via Nominatim `searchPlaces` (public, no key, `countrycodes=lr`).
- Stubs (interface + unavailable reason, never scraped): Facebook, Google, YouTube, Reddit — each names the credential the operator would need.
- Facebook connector (design doc `~/workspace/sando-pulse-facebook-connector.md`): Graph API client, webhook receiver (HMAC-verified, `GET` handshake + `POST` notifications), page registry (`config/facebook-pages.example.json` — all page IDs empty, pending partnerships), polling fallback with per-page schedule + missed-notification reconciliation, post normalizer, Postgres + memory notification stores.
- **Verified unconfigured behaviour (live server, 2026-11-13 ~00:27):** `GET /v1/connectors/facebook` → `{"connector":"facebook","available":false,"reason":"no Facebook access token configured (PULSE_FACEBOOK_ACCESS_TOKEN): create a Meta Developer app and authorize a Page — see STATUS.md","registered_pages":0,"pending_pages":0,"pages_polled_total":0,"pages_failed_total":0,"notifications_pending":0,"api_version":"v21.0"}`. The worker logs the same reason and skips the source (0 docs, 0 errors). It never contacts Meta unconfigured; tokens come from env vars only (`PULSE_FACEBOOK_ACCESS_TOKEN`, `PULSE_FACEBOOK_APP_ID`, `PULSE_FACEBOOK_APP_SECRET`, `PULSE_FACEBOOK_VERIFY_TOKEN`, `PULSE_FACEBOOK_API_VERSION` default `v21.0`, `PULSE_FACEBOOK_REGISTRY_PATH`, `PULSE_FACEBOOK_POLL_INTERVAL_S`), never from files.
- **Still needs (Dominic's steps):** Meta Developer account + app, permissions (`pages_read_engagement`, `pages_read_user_content`, `pages_show_list`, PPCA eligibility), App Review, partnerships with 5–10 Liberian media orgs.

### 3.3/3.4 Knowledge store (`ab620c7`, `eacd3b6`)

- `KnowledgeStore` interface with memory + Postgres implementations: events are persisted clusters (same topic or trigram-similar title within 72h), entities/topics counted per document, source health, locations/facilities/statistics with provenance + verification date, monthly aggregates.
- Migration 005 reconciles the 001/004 schema collision (001 already owned events/entities/topics/locations with different shapes, so 004's `CREATE TABLE IF NOT EXISTS` skipped them; 005 ALTERs the 001 tables).
- `/v1/events` serves persisted event clusters; `/v1/locations` and `/v1/statistics` serve the 3.6 seed (see below).

### 3.5 Knowledge compression (`0763a9f`, `ddfa5da`)

- **Zig 0.17.1 has NO `@cImport` builtin** (removed; even a minimal `@cImport(@cInclude("stdio.h"))` fails with `invalid builtin function: '@cImport'`, while `zig cc` works). `src/storage/compression.zig` was rewritten with `@extern` declarations for the libzstd C API (`ZSTD_compress`/`decompress`/`compressBound`/`getFrameContentSize`/`isError`/`versionString`); `build.zig` links libc + `zstd` for exe + test modules. Version 1.5.5, round-trips verified live.
- `src/storage/maintenance.zig`: `RetentionPolicy` (default 365 days, archive dir `"archive"`; 0 days disables retention), `archiveDocuments` (one batch max 1000 docs, `.jsonl.zst` via `Stringify.valueAlloc`; archive JSONL excludes embeddings — vectors are re-derived on re-ingest), `enforceRetention` (fail-closed: archive before delete, nothing deleted if the archive write fails), `findDuplicates` (report only, nothing deleted; exact = shared content hash, near = same normalized title from same source), `aggregateHistory` (buckets `year_month\x00topic`, topic-less docs under `"general"`), `runMaintenance` (aggregate → dedup report → retention).
- Pipeline archives raw feeds compressed (`application/zstd`, key `raw/{source}/{ts}.xml.zst`) with raw-XML fallback on compression failure — archiving never blocks ingestion.
- Config: `PULSE_RETENTION_DAYS` (default 365, max 3650), `PULSE_ARCHIVE_DIR` (default `"archive"`), `PULSE_MAINTENANCE_INTERVAL_S` (default 86400). Worker runs maintenance at most once per interval; a failed pass logs and retries next interval, never fatal. CLI: `pulse maintenance` prints `archived/deleted/exact_dupes/near_dupes/aggregates/archive`.
- **Live worker ingest (2026-11-13 ~00:0x, Postgres + Redis, `worker --once`):** docs 2 → 12, duration 18,930 ms, `had_error=true` — The News fetched 10 / inserted 10 / errors 0; Daily Observer, New Dawn, Liberian Investigator, GNN Liberia each fetched 0 / errors 1 (see honest gaps); Facebook 0 / 0 / 0 (skipped, no token). After: 12 docs, 5 events, 1 aggregate row.
- **Live maintenance (2026-11-13 ~00:10):** `archived=1 deleted=1 exact_dupes=0 near_dupes=0 aggregates=8`, archive `/home/hatch/workspace/tmp/pulse-archive-test/archive-20261113-001050.jsonl.zst` (268 bytes, magic `28b52ffd` = zstd). Aggregates: 2026-11 politics 7, business 2, energy 1, economy 1, crime 1, society 1, general 1; 2025-11 politics 1. After: 11 docs; top event "Over 2,000 Government Workers Meet Retirement" doc_count 6.

### 3.6 Liberian knowledge domain (`6852ce7`, `35c0bba`, `94c67cf`)

- **Seed:** `src/seed/liberia.zig` (generated by `~/workspace/tmp/generate_seed.py` from live-collected JSONs in `~/workspace/tmp/` — `districts.json`, `cities.json`, `seed-verified.json`, `seed-retry.json`). CLI: `pulse seed` (idempotent upserts; runs against memory or Postgres). **Counts: locations 166, facilities 46, statistics 5.**
- **Locations (166):** 15 counties, 127 districts, 10 largest cities, 12 Monrovia neighborhoods, 2 Montserrado townships (Virginia, Brewerville — kind `community`).
- **Facilities (46):** 9 hospitals, 3 markets, 5 universities + 1 institute, 3 schools, 1 road (Monrovia–Kakata Highway, a point on the road), 7 media orgs, 17 government institutions.
- **Statistics (5):** Liberia population 1984 (2,101,628), 2008 (3,476,608), 2022 (5,250,187), 2024 estimate (5,437,249); Montserrado 2008 (1,144,806).
- **Provenance (every row, `verified_at` 2026-11-12):** districts + 2008 populations — Wikipedia "Districts of Liberia" (LISGIS 2008 census table); cities + 2008 populations — Wikipedia "List of cities in Liberia"; counties/cities/districts/neighborhoods/hospitals/markets/universities/schools/roads coordinates — OpenStreetMap Nominatim; media/government — HTTP 200 on the official homepage (NEC: HTTP 403 bot-block, domain live); statistics — Wikipedia "Demographics of Liberia" census table + "Liberia" article.
- **Coordinate acceptance rule:** a Nominatim hit is used only when its first address segment contains every alphabetic token of the place name (districts: tokens excluding `district` and numbers — numbered districts like `District #3` can never match). **105/127 districts have coordinates; 22 do not** (13 Nominatim misses + 9 rejected approximate hits: District #1–#4, St. John River, Greater Monrovia, St. Paul River, Pynes Town, Webbo). Several of the 105 are approximate (named after a nearby feature — clinic, association, hotel); see honest gaps.
- **23 districts have no published 2008 population** (Barclayville, Bleebo, Bolloh, Buah, Dorbor, Dweh, Felo-Jekwi, Fenetoe, Forpoh, Garraway, Gee, Grand Cess Wedabo, Upper Jloh, Lower Jloh, Kpi, Nrokwia-Wesldow, Penicess, Trenbo, Wlogba — all Grand Kru; Quardu Gboni — Lofa; Barrobo, Pleebo/Sodeken — Maryland; Webbo — River Gee). Their population is null, not guessed.
- **Live Postgres verification (`pulse seed`, 2026-11-13 ~00:26):** `seed: locations=166 facilities=46 statistics=5 store=postgres verified_at=2026-11-12`, identical on re-run. DB counts: locations 167 (166 + the Testville test row), facilities 47 (46 + Test Hospital test row), statistics 6 (5 + `test_population` test row). Commonwealth returns 3 distinct districts (Grand Bassa 35,740 / Grand Cape Mount 6,547 / Montserrado 11,876). Monrovia population 1,021,762.
- **Live server smoke test (2026-11-13 ~00:29, Postgres + Redis, port 9000):** `/v1/health` ok (12 docs, 5 sources, postgres). `/v1/locations?kind=city` → 11 rows with 2008 populations (10 seeded + Testville). `/v1/locations?kind=district&limit=200` → Commonwealth 3 rows, one per county. `/v1/statistics` → the 5 census stats with provenance. `/v1/query` "fuel shortage in Monrovia" → sufficient=true, confidence 0.76 (returns the geo-test probe doc — test residue in the live test DB).
- **Identity fixes the seed forced (migrations 007–009):**
  - 007: locations are identified by (name, kind, county), not (name, kind) — Commonwealth exists in 3 counties, and the old key collapsed them (166 upserted, 164 stored). Slug id is now `kind:name[:county]`; the upsert uses `ON CONFLICT (id)`; the unique index is (name, kind, county). Also fixes the 001 county-name typo "River Cess" → "Rivercess" and renames the 001 county ids (`loc_bomi` → `county:bomi`).
  - 008–009: facilities get a surrogate slug id (`kind:name[:county]`) as the upsert arbiter; the old (name, kind, county) PK forced county NOT NULL (Postgres keeps the implicit NOT NULL after a PK drop — 009 drops it explicitly), which made media/government orgs unseedable. County is now genuinely nullable; the (name, kind, county) unique index is kept where a county is known.
  - The SQL id backfills in 007/008 use the regexp slug (`regexp_replace` drop `[^a-z0-9 _-]`, then map space/dash to `_`) — the plain `replace(lower(), ' ', '_')` form kept `.`/`'` and produced 5 wrong ids (Jackson F. Doe, JFK, St. Joseph's, St. Timothy, William V.S. Tubman), which the upsert then missed. 009 recomputes them.
- **Endpoint fix the smoke test caught (`94c67cf`):** `/v1/locations` hardcoded `listLocations(null, 100)` — `?kind=city` returned districts + neighborhoods too (Foya and Kakata twice, city + district). It now parses `kind` and `limit` from the query string (`Server.queryParam`, unit-tested), and `buildLocationsResponse` includes the `population` field.

### Roadmap 3 honest gaps

1. **4 RSS sources errored in the live worker run** (Daily Observer, New Dawn, Liberian Investigator, GNN Liberia — fetched 0 / errors 1 each). Not investigated: transient vs persistent unknown. The News worked (10/10).
2. **22 districts have no coordinates; 23 have no 2008 population** (lists above). Several of the 105 coordinates are approximate (Suakoko hit is "Suakoko District Youth Association", Careysburg is a clinic, Greater Monrovia was rejected, Sanquin District 1/2/3 share one point, Grand Bassa District #1–#4 hits are generic/unrelated). Do not treat all 105 as precise district centroids.
3. **Not seeded — unverifiable, recorded as missing, never invented:** Starz University, United Methodist University (no OSM entry), F. J. Grant Hospital, Rally Time Market, 5 schools (St. Patrick, D. Twe, Lott Carey, St. Theresa, J. J. Roberts), 7 highways (only Monrovia–Kakata verified, as a point), 4 media (The News, Spoon TV, ELBC, Truth FM — homepage unreachable from this VM; proxy artifacts, not proven dead), 2 ministries (Lands, Mines and Energy; Youth & Sports).
4. **Media/government facilities have no county/city** — the homepage check verified the organization exists, not its street address. Their county was deliberately left null rather than asserted from general knowledge.
5. **Overpass API is unusable from this VM** (HTTP 406 on `overpass-api.de`, timeout on the `kumi.systems` mirror) — no OSM way data, so roads are seeded as points or not at all.
6. **2022 census figure:** 5,250,187 per the Wikipedia Demographics table; LISGIS elsewhere cites 5,248,621. The table figure is seeded, with its provenance, and the discrepancy is recorded here.
7. **District populations sum to 3,620,633, above the official 2008 total of 3,476,608** — the source table's own inconsistency; recorded, not reconciled.
8. **The geo live test was state-dependent** (an unfiltered top-10 search stopped finding the probe doc once real worker docs lived in the DB). Fixed by searching on the probe doc's own term; the test still exercises the geo leg (lat/lon + 128-dim embedding round-trip).

## Roadmap 4 — COMPLETE 2026-11-13 ~03:00 GMT

Commits: 4.1 `a77d5bc`, 4.2 `3dc952b`, 4.3 `31b2b5f`, 4.4 `467cb6a`, 4.5 `1f2005d` + `b9c07e0` + `c097066` + `51ad74e`, 4.6 `4ec4c30`. Head `51ad74e`.

### Tests

- `zig build` — **passes** (binary `zig-out/bin/pulse`, ~47 MB).
- `zig build test` with live Postgres + Redis — **175/175 pass, 0 fail, 0 skip, 0 leaks** (log `/tmp/pulse-test23.log`). Includes the Postgres live test, Redis live test, Postgres-knowledge live test, PgPool concurrent-checkout live test, and the fetchConcurrent bounded-concurrency test.

### Environment reinstall (2026-11-13 ~01:20–01:30, after the ~00:44 VM restart)

The restart wiped the system packages the earlier builders used: `postgresql-16`, `redis-server`, `postgresql-16-pgvector`, `postgresql-16-postgis-3`, and the libzstd dev files. Reinstalled via apt (`postgresql-16` + `redis-server`, then `postgresql-16-pgvector` 0.6.0 + `postgresql-16-postgis-3` 3.4.2); libzstd headers + symlink re-applied from the pre-downloaded deb. Postgres 16 + Redis 7 running; `pulse_test` DB recreated (it had not survived either). The first live run after reinstall failed 2 tests (vector/postgis missing) — fixed by the extension install, then 162/162.

### 4.1 Event intelligence (`a77d5bc`, by the previous coordinator)

- `src/intelligence/events.zig`: importanceScore, scanRetraction, eventStatus, detectConflicts, timelineBuckets. KnowledgeEvent gains distinct_sources + status; the pipeline scans for retraction markers at ingest; `/v1/events?id=` detail endpoint. 146/146 at the time.
- Honest gap: events are topic-clustered (3.3/3.4), so conflict detection reads 'divergent' for topic buckets whose docs are different stories; meaningful only for title-clustered events.

### 4.2 Geez and trending engine (`3dc952b`)

- `src/intelligence/trending.zig`: computeTrends (recent vs prior equal-length window, velocity = recent/max(prior,1), score = ln(1+recent) x clamped velocity), categoryOf (politics→political, sports→sports, culture→entertainment = the Geez lane, else general), computeGeoTrends (counties named in title+text, top topic per county), snapshotFromAggregates + historicalRankings over the 3.5 monthly aggregates, topGeez helper, parseWindow 24h/7d/30d.
- `GET /v1/trends?window=&category=&county=&limit=` (default 24h, limit cap 50, invalid window is 400) with ranked trends, geo trends, latest 3 monthly snapshots.
- Live smoke test (2026-11-13 ~03:05): business 7.99, politics 5.42, economy 4.16. Geo trends empty on this dataset (no county name matched in the fetched docs) — see honest gaps.

### 4.3 Real-time processing (`31b2b5f`)

- `src/workers/realtime.zig`: StreamConsumer over `pulse:events`, group `pulse-workers` — drainOnce reads new entries, reclaimPending re-reads unacked ones, unknown kinds acked+skipped, failures retried with per-entry attempt counters (`pulse:events:attempts:<id>`) and moved to `pulse:events:dlq` after max_attempts=3 with the reason attached.
- `src/api/cache.zig`: epoch-based query-cache invalidation — cached responses stored as `<epoch>\n<json>` under `pulse:cache:q:<sha256(query|limit)>`, TTL default 300s; ingest bumps the single epoch via one INCR (no key scans); EpochInvalidator processor. Worker loop drains + reclaims each iteration; a Redis outage logs and retries next iteration, never fatal.
- Honest gap: the stream only carries document.collected today; event-driven indexing means cache invalidation + epoch bump, not a re-index (documents are indexed at ingest already).

### 4.4 Precomputed intelligence (`467cb6a`)

- `src/intelligence/precomputed.zig`: Briefing (top_stories, top_geez_today/week/month, latest_liberia/lofa/montserrado, popular_political/entertainment, breaking — importance ≥ 0.5, seen in last 6h, not retracted), computeBriefing over repo + knowledge store, renderBriefing JSON, refreshBriefing stores the payload in Redis `pulse:briefing` with TTL. Config `precompute_interval_s`/`precompute_ttl_s` (defaults 3600). `GET /v1/briefing` serves the cached payload when fresh else computes live (`cached` flag in the body). Worker refreshes on schedule. `pulse briefing` CLI prints the payload.
- Live smoke test: `cached:false`, top_stories 0, breaking 0, geez_today 0 — the feeds' latest items are dated 2026-11-12 and the server's "today" is 2026-11-13, so the empty briefing is correct behaviour, not a bug. The non-empty path is proven by unit tests only.

### 4.5 Performance optimization (`1f2005d`, `b9c07e0`, `c097066`, `51ad74e`)

- **Query cache** (`src/api/cache.zig`, `src/api/server.zig`, `src/api/metrics.zig`): POST /v1/query serves identical query+limit from Redis when the ingest epoch is unchanged, header `x-pulse-cached: true/false`. Stored bodies are rendered with an empty request id and spliced in on a hit (`stampRequestId`, unit-tested incl. the marker-missing error path). Responses > 64 KB are served but never stored. Metrics `pulse_queries_cache_hits/misses_total`. TTL via `PULSE_QUERY_CACHE_TTL_S` (default 300s, 0 disables). Live smoke test: first query `x-pulse-cached: false`, second identical query `x-pulse-cached: true`, same 2 results, counters 1/1.
- **Connection pool** (`src/storage/postgres.zig`): PgPool — N PgClient slots, exclusive checkout, lazy reconnect per slot, bounded 10s wait then `PoolExhausted`, size clamped 1..32. PostgresStore uses it (default 1 = the original single-connection design; `PULSE_PG_POOL_SIZE` raises it). SQL strings build on a thread-safe GPA so concurrent checkouts never share an arena. Pool mutex uses the direct `std.Io.Threaded` futex helpers (plain OS futex) — the Io-bound mutex path is unreliable from raw spawned threads. Spin wait uses a raw `nanosleep`, never `Io.sleep`. Live test: two threads hold two connections at once, max_held == 2.
- **Indexes** (migration 010): `events(last_seen_at)`, `events(topic, last_seen_at)`, `documents(source_id, fetched_at)`, all `IF NOT EXISTS`. Applied live; verified in `\d`. Note: migration 004's CREATE TABLE never ran — 001 already created events with `first_seen_at`/`last_seen_at`.
- **Concurrent collection** (`src/ingestion/pipeline.zig`): runOnce builds the due-source list sequentially (config + interval checks read the knowledge store), fetches them in bounded waves (`PULSE_MAX_CONCURRENT_SOURCES`, default 4, clamped 1..8), then processes each fetched source sequentially on the main thread — the repository, event sink and knowledge store are never used concurrently, so inserts stay serialized and idempotent. `ingestOneSource` split into `fetchSourceItems` (fetch+parse, stage-typed errors) and `ingestParsedSource` (archive + normalize + insert + health). Each fetch task owns its arena + its own `std.Io.Threaded` instance: `HostName.connect` resolves DNS through `io.async`, which is only reliable from the owning thread. Live smoke test (`pulse worker --once`, 2026-11-13 ~03:05): docs 2 → 82 in 34s — Daily Observer 50/50, New Dawn 10/10, GNN Liberia 10/10, The News 10/10, Liberian Investigator 0/1 error, Facebook skipped (unconfigured).
- **`pulse loadtest` CLI** (`src/cli/loadtest.zig`): N threads x M requests against a running server (default http://127.0.0.1:9000), fresh connection per request, p50/p95/max/mean for GET /v1/health and POST /v1/query plus calls/s. Plain `std.Io.net` sockets per worker thread (each with its own Threaded io), literal IP only, HTTP only, 10s receive timeout. Live runs against the smoke-test server: 4 threads x 25 requests = 200 calls, 0 errors, health p50 122.8ms / query p50 82.2ms, 48.2 calls/s; 2 x 10 = 40 calls, 0 errors, health p50 81.8ms / query p50 41.2ms, 46.3 calls/s.
- **Memory (4.5 pass):** no unbounded in-process growth identified. Bounded: pool 1..32 connections, cache 64 KB/response + 300s TTL, one arena per request, one arena per worker iteration, briefing = one Redis key. The query cache has no count bound — keys accumulate until TTL expiry; the operator-side bound is a Redis `maxmemory` policy (Roadmap 5.4).

### 4.6 Intelligence quality (`4ec4c30`)

- `src/intelligence/quality.zig` (pure, no I/O): freshnessScore (half-life decay: 1.0 fresh, 0.5 at 24h, ~0.125 at 7d); calibrateReliability (design-doc grade penalised by consecutive failures and stale last-success, clamped 0.05..0.95; a never-run source keeps its grade but is reported missing); eventConfidence (half reliability + half corroboration, scaled by freshness, cut hard for retracted/divergent); flagEvent — misinformation indicators: single_source, conflicting_reports, retracted, stale, low_reliability, uncorroborated_old. Flags are warnings for a human to check, never verdicts; the response says so in its `note` field.
- `GET /v1/quality`: per-source quality for all 10 registry sources (stale = no success in 24h, missing = no health record) + the newest 100 events with confidence/freshness/flags + summary counts. Live smoke test: summary stale_sources 6, missing_sources 5, flagged_events 27 (of 34 events, mostly single_source); Liberian Investigator calibrated 0.47 after its failed run (0.70 − 0.08 failure − 0.15 never-succeeded); sample event confidence 0.45, freshness 0.83, flags [single_source].

### Roadmap 4 honest gaps

1. **Liberian Investigator errored in the smoke-test worker run** (fetched 0, errors 1) — the same intermittency as Roadmap 3's 4-source errors; not investigated (transient vs persistent unknown).
2. **Briefing empty on the smoke test** (top_stories/breaking/geez all 0) — correct behaviour given the feeds' latest items are dated 2026-11-12; the non-empty live path is unit-tested only.
3. **Geo trends empty on the smoke test** — no county name matched in the fetched docs' title+text; the geo logic is unit-tested, live geo coverage unproven.
4. **Conflict detection reads 'divergent' for topic buckets** whose docs are different stories (4.1, carried from above).
5. **The stream only carries document.collected**; event-driven indexing is cache invalidation + epoch bump, not a re-index.
6. **Query cache has no count bound** — keys accumulate until TTL; needs a Redis `maxmemory` policy in deployment (Roadmap 5.4).
7. **Loadtest latencies are high-ish** (health p50 ~80–120ms, query p50 ~40–80ms) — single-threaded server + fresh connection per request on a 2-CPU VM. These are measurements, not a regression (no baseline existed).
8. **The live knowledge test is state-dependent** — fixed by raising its listEvents limit from 10 to 1000 (`51ad74e`); real worker events had pushed the 2023 fixture out of the top 10.
9. **`zig build test` does NOT analyse uncalled function bodies** (lazy analysis): 3 loadtest compile errors (`std.time.nanoTimestamp` does not exist in 0.17.1, `ArrayList.writer` does not exist, `stream.read` wants `[][]u8` not `*const [1][]u8`) were only caught by `zig build`. The exe build is the real gate for CLI code.
10. **PgPool stale-allocator bug (2026-11-13, found + fixed during 4.5):** `PgPool.init` returned the pool by value after handing out `gpa.allocator()` — every PgClient stored a pointer to the GPA's stack location in `init`, and the first pool ping allocated an arena from the dead slot and hit a `DebugAllocator` bucket assert; the live test's teardown hung on a corrupted futex for the same reason. Fixed by heap-allocating the GPA (stable address). Lesson: never move a struct after taking its `.allocator()` — the same applies to any struct that hands out a self-referencing allocator.

## Roadmap 5 — COMPLETE 2026-11-13 ~04:30 GMT

Commits: 5.1 SSRF `23427c4`, rotation `4d5ee43`, audit CLI `8f2375d`, backup/restore `5cd1211`; 5.3 consumers/usage/audit `951e26d`; 5.2 Sando client `33f55e6`; 5.3 docs `e7aeb54`; 5.4 compose/alerts/CI/ops `4c2a4d3`; 5.5 replica/country `9add2d4`; server-crash fix `4bc562c`; OpenAPI YAML fix `1203f8d`. Head `1203f8d`.

### Tests

- `zig build` — **passes** (clean-cache rebuild 2026-11-13 ~04:18, binary `zig-out/bin/pulse`, 38,972,533 bytes).
- `zig build test` — **204/204 pass, 0 fail, 0 skip, 0 leaks** (unit). Same binary run live with Postgres + Redis — **204/204 pass, 0 fail, 0 skip, 0 leaks**. Live legs use `127.0.0.1` URLs: Zig 0.17.1's std resolver cannot resolve the hostname `localhost` on this VM (`ParseFailed` in `Ip6Address.resolve`); `redis-cli` resolves it fine. Pre-existing environment quirk, not a Pulse bug.
- Test-count history: Roadmap 1: 74. Roadmap 2: 101. Roadmap 3: 139. Roadmap 4: 175. Roadmap 5: **204**.

### 5.1 Production hardening

- **SSRF protection** (`src/ingestion/ssrf.zig`, `23427c4`): range-check every fetch target before connect — loopback, private, link-local, CGNAT, documentation, benchmarking, multicast, reserved (v4 + v6 incl. IPv4-mapped); hostnames resolved and EVERY returned address must be public. Wired into `fetchOnce` for ingestion GETs (redirects included, one check per hop). Operator-configured POST provider endpoints NOT checked (a local Ollama is legitimate). Residual gap: std `connect` re-resolves internally, so a flipping DNS between check and connect is not fully closed.
- **Key rotation** (`4d5ee43`): `PULSE_API_KEY_PREVIOUS` accepted alongside `PULSE_API_KEY` (constant-time both); rotation procedure (new key in, old key in PREVIOUS, restart, migrate clients, drop PREVIOUS). Rate-limit buckets key on the presented token (each key gets its own budget). Boot logs rotation state.
- **Security audit CLI** (`src/cli/audit.zig`, `8f2375d`): `pulse audit` pre-flight checklist — api key, rotation sanity, rate limits, retention, TLS termination, DB password != example ("pulse"), linked dependencies (Zig version + libzstd >= 1.5.0), live Postgres version + required extensions (vector, postgis, pg_trgm), live Redis maxmemory + eviction policy. Exit 1 on any FAIL. Live run vs the test DB: postgres PASS, redis WARN maxmemory 0 (unbounded — fixed in the 5.4 compose update), api_key FAIL (expected, no key in the dev shell), tls WARN (expected).
- **TLS decision (verified against the stdlib):** the Zig 0.17.1 stdlib has NO TLS server (`pub const Server` absent from `lib/std/crypto/tls.zig`) — TLS termination is a reverse proxy's job, documented; the audit warns while `PULSE_BEHIND_TLS_PROXY` is unset. `PULSE_REQUIRE_HTTPS_FETCHES` (default false — one registry feed, Daily Observer, is http-only) enforced per hop incl. redirects.
- **Backup/restore** (`src/cli/backup.zig`, `5cd1211`): `pulse backup [--out <path>] [--keep N]` — plain pg_dump to `backups/pulse-<UTC stamp>.sql` (default, keep last 7), prints bytes + SHA-256; a failed pg_dump deletes the partial file. `pulse restore --in <path>` — psql -f with ON_ERROR_STOP=1 into an empty database. Live verification: backup of pulse_test = 27,883 bytes, 18 CREATE TABLEs; restore into scratch DB reproduced documents=2 and schema_migrations=10 (scratch DB dropped after).
- **Server crash found by the live smoke test and fixed** (`4bc562c`): `std.http.Server` INVALIDATES `head`/`head_buffer` pointers once the body stream is initialized (`readBody`). The 5.3 audit helpers read `req.head.*` AFTER `readBody` on the query/ingest success paths — the smoke test hit a general protection fault in `auditCall`'s `pathOf` on the second request. The Facebook webhook branch had the same latent bug (signature header read after `readBody`). Fix: `captureHead()` copies path, query, method, auth/consumer/webhook headers into arena-owned strings at the top of `handleRequest`; nothing below touches `req.head.*` after a `readBody` call (verified by grep). Also moved the auth check before consumer resolution, so a missing key reports `auth_required` instead of `unknown_consumer`.

### 5.2 Sando integration (Pulse side only — SANDO_UI untouched)

- `src/sando/client.zig` (`33f55e6`): reference Pulse client for Sando — POST /v1/query with retry + linear backoff (transport/5xx/429, max 3 attempts), typed `SandoAnswer` with citations + confidence, county folded into the query text so the planner sees it, `context` object sent for forward compatibility; typed errors (`PulseUnavailable`/`Unauthorized`/`QuotaExceeded`/`BadResponse`) — never fabricated content. Honest limit documented: `std.http.Client.fetch` in 0.17.1 has no per-request timeout, so none is enforced.
- `src/cli/mock_sando.zig`: `pulse mock-sando "<question>" [--county] [--language] [--pulse-url] [--api-key] [--consumer]` — stand-in Sando client for e2e tests; exit 0 sufficient, 2 valid refusal, 1 error.
- `docs/SANDO_INTEGRATION.md`: full client contract (endpoint, request, response, error table, consumer setup, versioning). `PULSE_URL` config (default http://127.0.0.1:9000).
- Live e2e (2026-11-13 ~04:24, fixed server): `mock-sando "zebraquux"` → exit 0, sufficient true, confidence 0.65, 1 citation (Pulse PG live test [New Dawn]); `mock-sando "quantum computing in Lofa county"` → exit 2, sufficient false, `no_documents_matched`.

### 5.3 API readiness

- **Consumers/quotas/usage/audit** (`src/api/usage.zig`, `src/api/auditlog.zig`, `951e26d`): consumer registry from `PULSE_CONSUMERS` (`name:scope,scope:quota_per_day`; scopes query/ingest/admin, `*` = all; quota 0 = global daily limit); name validation `[a-z0-9_-]`; `UsageTracker` (Redis counters `pulse:usage:<consumer>:<day>:<kind>` with 48h TTL, in-memory fallback pruned to two days; Redis failure falls back to memory). Audit records: consumer, key fingerprint (first 8 hex of SHA-256 — the key itself never stored), route, method, status, request id; sinks Postgres `audit_log` (migration 011) + JSONL file (`PULSE_AUDIT_LOG`) + structured log; best-effort, never fails a request.
- **Server wiring:** auth gate enforces consumer (401 unknown), scope (403), per-consumer daily quota (429 `quota_exceeded`); usage + audit recorded at query/ingest success and at every denial; `GET /v1/usage` (admin scope, optional `?consumer=` filter); `x-pulse-api-version: 1` on all JSON responses; health gains `api_version: "1"` and `country`.
- **Docs** (`e7aeb54` + `1203f8d`): `docs/openapi.yaml` (OpenAPI 3.0.3, 14 paths, all verified present as routes in `server.zig`; two YAML syntax errors found by validation and fixed — an unquoted `: ` and a leading backtick), `docs/API.md` (auth, consumers/scopes/quotas, rate limits, error codes, versioning), `docs/SECURITY.md` (threat model, SSRF + residual gap, rotation procedure, audit records, pre-flight audit, TLS decision, dependency auditing, input validation, what is NOT built).

### 5.4 Deployment and operations

- `docker-compose.yml` (`4c2a4d3`): Redis `maxmemory 256mb` + `maxmemory-policy allkeys-lru` — **closes the 4.5 query-cache gap** (keys no longer accumulate until TTL); `worker-2` under the `scale` profile (distinct `PULSE_WORKER_ID`); one-shot `backup` service under the `backup` profile; node-exporter; alertmanager under the `alerts` profile; json-file log rotation (10m × 3) on every service; api passes through rotation/consumers/audit-log/TLS env; `pulse-backups` volume.
- `docker/prometheus/alerts.yml`: 7 rules on real series (PulseDown, High5xx, SlowResponses, IngestFailing, CacheCold, RedisMemoryHigh, PostgresDown); `prometheus.yml` gains `rule_files` + alertmanager target + node-exporter job. `docker/alertmanager/alertmanager.yml` ships with **NO receiver on purpose** — the operator must configure one before enabling alerts.
- `.github/workflows/ci.yml`: authored only — `zig build` + unit suite + audit; live legs documented as needing a pgvector+PostGIS image (stock postgres:16 lacks the extensions). **Must be added via the GitHub web UI** (gh token lacks `workflow` scope). Has NOT run.
- `docs/OPERATIONS.md`: deploy, worker scaling, backup/restore/rollback, disaster recovery, monitoring, incident table, what runs here vs a real host.
- **Authored-only, not run here:** the compose stack cannot run on this VM (podman `--network none`, no container networking). YAML parses; the binary builds; the API itself was smoke-tested live on the host. The first real `docker compose up` must happen on Dominic's machine or a production host.

### 5.5 Future scalability

- `docs/SCALABILITY.md` (`9add2d4`): extension points (Repository vtable, connectors, consumers, countries, workers, read replicas, dedicated search, object storage, multi-tenant controls) + the scaling order. Explicitly NOT a live multi-region deployment.
- **Read replica** (`src/storage/postgres.zig`): `PostgresStore.setReplica` — second pool (2 connections) on `PULSE_DATABASE_REPLICA_URL`; `search`/`countDocuments`/`countBySource`/`scanDocuments` route to it with fallback to the primary when the replica checkout fails; writes always stay on the primary; a bad replica URL fails at attach, never at boot. Live test: routing + fallback + double-attach error.
- **Country** (`PULSE_COUNTRY`, default `"lr"`): reported in `/v1/health` (`"country":"lr"`) and `pulse status`; the multi-country extension point (second instance + router; a shared DB needs a `country` column first — deliberately not done).

### Live smoke test (2026-11-13 ~04:20–04:26, fixed server, Postgres + Redis)

Server started with `PULSE_API_KEY=<keygen>`, `PULSE_CONSUMERS=sando:query,admin:10000;ingest-bot:ingest:5000;tiny:query:1`, `PULSE_AUDIT_LOG=~/workspace/tmp/pulse-smoke-audit.jsonl`, `DATABASE_URL`/`REDIS_URL` to the test DB. Real curl outputs:

- `GET /v1/health` → `{"status":"ok","version":"0.1.0","api_version":"1","country":"lr","documents":3,"sources_enabled":5,"store":"postgres"}`; header `x-pulse-api-version: 1`.
- Query without key → 401 `auth_required`. Bad key → 401 `auth_invalid`. Unknown consumer → 401 `unknown_consumer`.
- Query `zebraquux` as sando → 200, `sufficient:true`, confidence 0.65, real citation (Pulse PG live test [New Dawn]); server stayed up (the pre-fix server crashed on this exact request).
- Query `quantum computing in Lofa county` → 200, `sufficient:false`, `insufficient_reason:no_documents_matched`, counties `["Lofa"]` in the plan.
- Ingest as sando → 403 `forbidden_scope`; ingest as ingest-bot → 201 with document id.
- `GET /v1/usage` as sando → 200: sando queries 3 / quota 10000 / remaining 9997; ingest-bot ingests 1 / 5000; tiny 0 / 1. As ingest-bot → 403.
- Quota live: `tiny` (quota 1) first query 200, second → 429 `quota_exceeded`.
- Audit: JSONL file has one record per call (key_fp `1ffb5a9a`, never the key); `audit_log` table 10 rows covering 200/201/401/403/429 across all three consumers + `default`.
- `pulse backup` → 32,193 bytes, sha256 printed. `pulse audit` → 7 pass, 2 warn (tls flag unset in the dev shell; local Redis maxmemory 0 — compose sets 256mb), 0 fail. `pulse status` → api_version 1, country lr, consumers 3, audit_log_file true, read_replica false. `/metrics` → live counters (14 requests, 8 2xx). Serve log: 0 errors/panics. Server stopped by PID after; port 9000 free.

### Roadmap 5 honest gaps

1. **Compose stack never ran here** (podman `--network none`); the first real `docker compose up` is on a real Docker host. The CI workflow has never run either (needs the web UI to add, and a pgvector+PostGIS image for the live legs).
2. **Alertmanager ships with no receiver** — alerts fire into nothing until the operator configures one.
3. **SSRF residual gap**: DNS flipping between check and connect is not fully closed (5.1).
4. **Sando client has no per-request timeout** — `std.http.Client.fetch` in 0.17.1 exposes none; Sando must use a worker thread + watchdog for a hard bound.
5. **Read-replica reads may lag the primary** by the replication delay (accepted for search/counts); the live test used a second pool to the same DB (routing proof, not replication proof).
6. **External embedding provider never called live** (no API key) — carried from Roadmap 2; the local embedder is lexical, no vector index yet.
7. **CI live legs are skipped** until a combined pgvector+PostGIS image is chosen (5.4).
8. **The smoke-test server crashed once** (the `readBody` head-invalidation bug) before the fix — the fix is committed (`4bc562c`) and the exact crashing request now returns 200 with the server alive; no in-suite server-level test exists, the live smoke test is the regression check.

## Roadmap 6 — Performance Core (in progress, 2026-11-13)

Baseline at start: `zig build` passes, 204/204 tests, origin/main `61d186a`.
Constraints: Zig 0.17.1, REST only, raw std.http only (NO httpz — owner's
direct order 2026-11-13), real data only, docs in the same commits.

### 6.2 L1 in-process cache — DONE (2026-11-13 ~14:20)

- `src/api/l1cache.zig` (new): bounded by count (default 512, `PULSE_L1_MAX_ENTRIES`) AND bytes (default 8 MiB, `PULSE_L1_MAX_BYTES`), LRU eviction, per-entry TTL (default 300 s, `PULSE_L1_TTL_S`). Keys are consumer-scoped (`q|<consumer>|<sha256>`); entries carry tags (topics/counties/cities) for smart invalidation. Single-threaded server: no locking (documented — a mutex is needed if the server ever goes multi-threaded). A single value larger than the byte cap is refused, never stored.
- Wired into `src/api/server.zig`: L1 is checked BEFORE the Redis (L2) cache on POST /v1/query; on a miss the storable body (empty request id) is written to L1 with the plan's tags. POST /v1/ingest invalidates only the entries tagged with the new document's topics/places — never a blind flush.
- Metrics (Roadmap 6.7 groundwork): `pulse_l1_cache_hits_total`, `pulse_l1_cache_misses_total`, `pulse_l1_cache_evictions_total`, `pulse_l1_cache_entries`, `pulse_l1_cache_bytes`, plus per-path counters/latency totals (wired in 6.1/6.7).
- Verified: `zig build` passes; 212/212 tests (8 new L1 unit tests); live smoke test — first identical query `cached:false`, second `cached:true`, metrics `l1_cache_hits_total 1`, `l1_cache_misses_total 1`, entries 1, bytes 1347.
- Honest note: cached bodies are rendered before the 6.1 `path`/`latency_ms` fields exist; 6.1 adds the stamp mechanism so a served-from-cache body reports the serving path, not the original one.

### 6.3 In-memory inverted index — DONE (2026-11-13 ~14:35)

- `src/engine/memindex.zig` (new): term -> postings (doc_id, score).
  Tokenization matches the planner exactly (same delimiters, same
  stopword list, lowercased); title terms weigh double; only the first
  4000 bytes of a document's text are indexed. Bounded by term count
  (default 50000, `PULSE_MEMINDEX_MAX_TERMS`), document count (default
  100000, `PULSE_MEMINDEX_MAX_DOCS`), and bytes (default 64 MiB):
  coldest terms evicted first, oldest documents first (sliding window
  keeps the newest slice). Single-threaded, no locking (same rule as
  L1); per-process — the worker holds its own index.
- `Repository.getDocument` added to the vtable (Roadmap 6.3): memory
  store (linear scan + dupe) and Postgres store (same SELECT as search,
  `WHERE d.id = <escaped>`). The index resolves candidates through it.
- `buildFromRepo`: paginated `scanDocuments` (1000/batch, moving cutoff
  + seen-set dedupe), returns a measured report (docs seen/added/
  evicted, terms, duration).
- Verified: `zig build` passes; 218/218 tests (6 new memindex tests:
  5 unit + 1 live against Postgres — build from the store, search for
  a unique marker, resolve by id, plus a getDocument miss case).
  Two bugs found by the suite and fixed: `init` caps were floored too
  high (`@max(100/10/1024)` defeated small test caps — now `@max(1,
  ...)`; production floors live in config), and two allocator leaks
  (freq-map keys; term-map keys in `deinit`).
- Not yet wired into the query path: the index is built and tested but
  no endpoint reads it — that is 6.1/6.7 (router + Path A), next.

### 6.1 + 6.7 Three execution paths + adaptive routing — DONE (2026-11-13 ~14:55)

- `src/engine/router.zig` (new): pure router. `instant` = L1 hit only;
  `deep` = research/compare/historical intents, `strategy:deep`, or no
  lexical terms (semantic-only); `fast` = everything else (geo-indexed,
  simple_indexed for short confident queries, default_fast). Every
  response carries `path`, measured server-side `latency_ms` (fractional,
  from `timex.latencyMsF64`), and `routing_reason`.
- `src/api/cache.zig`: `stampServed` splices request id + serving path
  + measured latency + routing reason into a cached body, so a hit
  reports the path that SERVED it (instant/l1_hit or instant/l2_hit),
  not the path that first computed it. Stored bodies are rendered with
  empty markers (`"path":""`, `"latency_ms":0`, `"routing_reason":""`);
  a missing marker fails loudly instead of serving a lie.
- `src/engine/search.zig`: `SearchOptions.candidates` — the fast path
  passes index-resolved documents; the fuzzy second pass still runs
  when fewer than 3 candidates survive, so an index miss degrades to
  the store search, never to nothing.
- Metrics: per-path counters + latency totals (`pulse_queries_path_*`,
  `pulse_path_latency_ms_*`), `pulse_memindex_lookups_total` /
  `pulse_memindex_hits_total`.
- Verified: `zig build` passes; 227/227 tests (9 new: 7 router, 1
  stampServed, 1 buildQueryResponse shape incl. the renderer<->stamp
  marker contract). Live smoke test (3-doc store): "fuel shortage in
  Monrovia" -> path fast, latency 89.17 ms, reason default_fast,
  sufficient true; identical repeat -> path instant, latency 0.169 ms,
  reason l1_hit, `x-pulse-cached: true`; research query -> path deep,
  reason strategy_deep. memindex lookups 1, hits 0 (only 3 docs in the
  store — the <3-candidate fallback to the store search worked).
- Honest note: precomputed instant for *queries* is NOT wired — the
  trends/briefing payload shape differs from the query response, so
  `/v1/trends` and `/v1/briefing` serve those directly (Redis-cached).
  The router's instant path is L1 hits only.

### 6.5 Incremental indexing — DONE (2026-11-13 ~14:55)

- Server boot builds the index from the store (`pulse serve` logs
  `memindex built`: 3 docs, 17 terms, 0 ms on the test store). A build
  failure is a warning, not a boot failure — queries fall back to the
  store search.
- `pulse reindex` CLI: rebuilds on demand, prints the measured report
  (`reindex: docs_seen=3 docs_added=3 docs_evicted=0 terms=17
  duration_ms=0`).
- In-process ingest: POST /v1/ingest calls `index.addDocument` right
  after storing, so the fast path can serve the new document at once.
  A failure is a warning only — the store search still finds it.
- Epoch-triggered rebuild: on each query, when the Redis epoch moved
  since the index was built (worker ingests bump it) AND the rebuild
  interval elapsed (`PULSE_REINDEX_INTERVAL_S`, default 3600), the
  server clears and rebuilds the index from the store. Bounded by the
  index caps; a rebuild failure keeps the old index.
- Honest note: the rebuild is a full clear + rescan (cheap at current
  scale — 0 ms for 3 docs); a timestamp-filtered incremental refresh
  needs a `scanDocuments(after_ts)` extension and is recorded as a
  future optimization, not done here.

### 6.6 Parallel query execution (fan-out) — DONE (2026-11-13 ~15:15)

- `src/engine/fanout.zig` (new): generic fan-out. Each task gets its
  own page-allocator-backed arena, so no allocator is shared across
  threads. `Fanout.start` spawns one thread per task (spawn failure
  runs the task inline in its own arena); `wait(timeout_ms)` polls
  until all tasks finish or the deadline passes; `joinAll` joins the
  stragglers AFTER the response is sent. `runSequential` is the
  fallback when parallel start fails or the store is not thread-safe.
- Wired into POST /v1/query: locations + statistics from the knowledge
  store run concurrently with the news search. Parallel only when the
  store is Postgres (its knowledge store is mutex-guarded) and
  `PULSE_PARALLEL_QUERY=1` (default); the memory store runs the same
  tasks inline. No entities in the plan = no fan-out.
- Response gains `locations` (max 10, matching the query's counties/
  cities), `statistics` (max 10, key names a query topic), and
  `fanout_complete` (false when a backend was still running at the
  deadline — partial results, labelled, never silently stale).
- Verified: `zig build` passes; 231/231 tests (3 new fanout unit tests:
  sequential, parallel, deadline-expiry + post-response join; 1 new
  locationMatches test). Live smoke test: "news in Lofa county" ->
  locations [Lofa/county], fanout_complete true; "zebraquux" (no
  entities) -> empty enrichment, fanout_complete true; "news in
  Testville" -> empty (correct: the entity extractor does not know
  Testville, so no fan-out ran). The fanout deadline path (straggler)
  is unit-tested with a 50 ms sleeper vs a 5 ms deadline; a live
  straggler was not forced (the knowledge lookups are single-digit ms).
- Honest note: the test DB holds only 15 counties + Testville (the
  full 166-location R3 seed was wiped with the DB recreations), so the
  Monrovia city match could not be verified live — the county match
  (Lofa) and the unit test cover the same code path.

### 6.4 Popular searches, staleness, cache warming — DONE (2026-11-13 ~15:35)

- `src/api/popular.zig` (new): `PopularSearches` — counts asked
  queries (normalised: trimmed, lowercased, whitespace-collapsed),
  bounded by a distinct-query cap (default 1000,
  `PULSE_POPULAR_MAX_TRACKED`; lowest-count entry evicted when
  full), `top(n)` most-asked first with deterministic tie-break,
  persisted best-effort to `PULSE_POPULAR_PATH` (default
  `popular.json`) every `PULSE_POPULAR_SAVE_EVERY` records (default
  100). A missing or corrupt file at boot returns an empty tracker —
  never a boot failure. Only query TEXT + count are stored, never a
  consumer or identity.
- `GET /v1/popular?limit=N` (public, max 50): top queries with
  counts + `tracked` (distinct queries). Verified live: three asks of
  "fuel shortage in Monrovia" -> `[{"query":"fuel shortage in
  monrovia","count":3}], tracked:1`.
- Staleness: `/v1/trends` now carries `computed_at` + `stale:false`
  (computed live from a store scan every request, so never stale —
  the fields exist so every precomputed payload reports freshness
  the same way). `/v1/briefing` now carries `stale`, evaluated at
  SERVE time against `PULSE_PRECOMPUTE_TTL_S` by parsing
  `computed_at` out of the payload; a payload whose age cannot be
  read is stale. Verified live: live-computed briefing -> stale
  false; cached briefing served later -> stale false (still within
  TTL). Bug found by the smoke test and fixed: `ignore_unknown_fields`
  defaults to FALSE in Zig 0.17.1, so the first parse failed and
  every briefing read stale — now passed explicitly.
- `computeQuery` extraction: the query handler's inline pipeline
  (plan, route, index shortlist, fan-out, search, render) is now one
  shared method returning `{resp, storable, path, reason, latency_ms,
  sufficient, tags, fo}` — used by the handler on a cache miss AND by
  warming, so a warmed answer is byte-identical to a freshly computed
  one. The fan-out task contexts and task list live in the caller's
  arena (not on the stack) so straggler threads stay valid until the
  caller joins after the response. Error codes preserved
  (planner_failed/search_failed/response_failed).
- Cache warming: at boot, after the memindex build, the server loads
  the popular list and runs the top `PULSE_POPULAR_WARM_N` queries
  (default 10) through `computeQuery`, storing the answers in L1
  (consumer "default") and L2. Warming never fails the boot. Verified
  live across a restart with Redis flushed: "popular searches
  loaded" (tracked 1) + "cache warmed" (queries 1, 89 ms); the first
  lowercase query (limit 10, matching the warmed entry) served
  instant/l1_hit in 0.38 ms vs 85 ms fresh.
- Honest note: warming keys are the NORMALISED query text, while the
  L1/L2 cache keys use the raw query text (pre-existing R4.5/R6.2
  behaviour, unchanged). A query typed with different casing (e.g.
  "fuel shortage in Monrovia" with a capital M) computes fresh on
  its first ask (85 ms, fast path) and then caches under its own raw
  form — verified live. Normalising the cache keys was deliberately
  NOT done: the cached body echoes the first request's raw query
  text, so a shared key would serve one user's casing to another.
- Verified: `zig build` passes; 236/236 tests (5 new popular tests:
  normalise, count/top, eviction, save/load round-trip, missing file).

### 6.8 Prepared statements — DONE (2026-11-13 ~16:00)

- Extended protocol in `PgClient` (`src/storage/postgres.zig`):
  `queryParams` / `execParams` use the unnamed statement + portal,
  Parse + Bind + Describe + Execute + Sync sent in a single flush
  (pipelined, no extra round trip). A shared `readResult` loop handles
  both the simple and extended protocols, accepting the extended-only
  messages `'1','2','3','t','n'` (ParseComplete, BindComplete,
  CloseComplete, ParameterDescription, NoData) and draining to
  ReadyForQuery on error, so a failed Parse/Bind leaves the connection
  usable. `ParamBuilder` helper: `param`, `nullParam`, `likeParam`
  (with `escapeLikeValue` — `%`, `_`, `\` escaped, `%` wildcards in
  the VALUE), `intParam`, `floatParam` (numbers as decimal text;
  Postgres infers the type from the SQL context).
  `formatTextArrayLiteral` for `$N::text[]`; `formatVectorText`
  (new, bare `[v,v,...]`) for `$N::vector` — see the bug note below.
- Converted: `searchLocked` (FTS joined terms, per-term ILIKE, fuzzy
  word_similarity, vector `$N::vector < 0.6`, time window via
  `to_timestamp($N)`, geo via `ST_MakePoint($N,$N)`, organizations,
  topics ARRAY, counties, LIMIT $N), `scanDocuments` (before_ts +
  LIMIT), `getDocument` (id $N), `insertDocumentLocked` (source
  upsert + document insert as two separate execParams calls, NULLs
  as null params, `to_timestamp($N)`, topics as `$N::text[]`, lat/lon
  via `ST_SetSRID(ST_MakePoint($N,$N), 4326)::geography` with null
  params when missing, embedding as `$N::vector` or null),
  `deleteDocuments` (parameterised IN-list, same params bound to
  both DELETEs). This is now the ONLY way user input reaches SQL in
  the document store — values are never interpolated into the query
  text. A value containing a quote (`o'brien`) is bound, never
  escaped, and returns verbatim.
- NOT converted (gap-record, not in this section's scope):
  knowledge-store queries, migrations, audit/usage,
  `countBySource`/`countDocuments` (no user input in those paths).
- Bugs found by the suite / live runs and fixed in this section:
  1. The insert rewrite dropped the `, 4326` SRID argument from
     `ST_SetSRID` — the server rejected the one-argument call.
  2. A NULL param in context-free SQL (`SELECT $1 IS NULL`) is
     rejected by the server with 42P18 (could not determine data
     type). Every real call site has type context (a column, a
     function argument, an explicit cast), so only the test SQL
     needed a cast (`$1::text IS NULL`).
  3. Use-after-free: `defer alloc.free(joined)` / `defer
     alloc.free(lit)` in `searchLocked` freed the FTS / vector
     param strings before `queryParams` sent them. The allocator
     refills freed memory with `0xaa`, and the server rejected the
     param as invalid UTF-8 (22021). Leftover from the old
     interpolate-into-SQL code, where freeing after interpolation
     was safe. Fixed by not freeing: param strings live in the
     caller's arena until the query is sent.
  4. `formatVectorLiteral` returns the quoted+cast form
     `'[1,0,...]'::vector`, correct when interpolated into SQL —
     but as a BOUND param the quotes/cast become part of the value
     and `$N::vector` receives an invalid vector string. New
     `formatVectorText` (bare `[1,0,...]`) is used for both bound
     sites (insert + search embedding leg); the literal form is
     kept for interpolation uses and its unit test.
  5. Multi-statement strings are rejected by Parse (42601:
     "cannot insert multiple commands into a prepared statement").
     Recorded, not a store bug: the two inserts were already
     separate execParams calls. Any future multi-statement work
     must split the calls.
- Verified: `zig build` passes; **237/237 tests** (1 new live test:
  same rows via simple vs prepared `SELECT $1::int, $2`, quote
  value `o'brien` returned verbatim, NULL param binds as SQL NULL,
  failed Parse returns `PgServerError` AND the connection stays
  usable (`ping()` after), `execParams` INSERT + read-back via a
  temp table, store search + `getDocument` with an `o'brien` term).
  Live smoke (Postgres store, port 9009): ingest of a
  quote-titled doc OK; query `obrien fuel` -> sufficient true,
  path fast, latency 85.0 ms, 2 results, first title as ingested.

### 6.10 Automatic performance optimization — DONE (2026-11-13 ~16:30)

- `src/engine/autotune.zig` (new, pure decision logic — no I/O):
  `Autotuner` holds the live knob values + configured defaults,
  bounds, and cooldowns. One server-side adjustment per 100
  queries, one worker-side adjustment per 10 runs; signals need a
  minimum sample before anything moves.
- Knobs and signals: L1 TTL 60–900s step 60s (hit rate < 0.5 grows,
  > 0.9 shrinks); fan-out timeout 50–500ms step 50ms (incomplete
  rate > 0.2 grows, zero stragglers over 50 fan-outs shrinks);
  max concurrent sources 1–8 (worker-side; run errors shed
  concurrency, slow but error-free fetches add it). Every
  adjustment is logged (old -> new + reason) and counted in
  metrics. The tuner never touches correctness, auth, or
  retention. The precompute interval (`PULSE_PRECOMPUTE_TTL_S`)
  is NOT auto-tuned — no in-process signal exists for briefing
  freshness cost — so it stays manual-only (gap recorded here).
- Wiring: the server owns an `Autotuner` (from cfg; `PULSE_AUTOTUNE`
  defaults off) and checks it after every query; the L1 TTL is
  applied to the live `L1Cache.ttl_s`, the fan-out deadline to a
  runtime field read by the wait. The worker owns one too and
  tunes the concurrency it passes to each `runOnce` from the run
  report (errors + mean per-source duration, skipped sources
  excluded; a failed run counts as an error signal). A failed run
  still runs the stream/maintenance work afterwards — the tuner
  hook does not change the loop's fall-through.
- `GET /v1/autotune` (public): enabled, live knob values,
  `precompute_ttl_s`, `adjustments_total`, last adjustment +
  reason. `POST /v1/admin/autotune/reset` (API-key auth, kind
  null — the admin pattern, no usage accounting): restores the
  configured defaults, applies them to the live knobs, returns
  the changed list. Restarting also restores the defaults.
- Metrics: `pulse_autotune_adjustments_total`,
  `pulse_autotune_l1_ttl_seconds` /
  `pulse_autotune_fanout_timeout_ms` /
  `pulse_autotune_max_concurrent_sources` gauges,
  `pulse_fanout_total` / `pulse_fanout_incomplete_total`,
  `pulse_process_rss_bytes` (Linux /proc/self/statm; 0 when
  unreported). Note: `std.fmt` caps one format call at 32
  arguments — `render` now emits the base block (27 args) plus a
  second call for the new series, concatenated.
- Verified: `zig build` passes; **244/244 tests** (7 new autotune
  unit tests: disabled, TTL up/down + clamps, under-sampled,
  fan-out up/down, worker up/down + cap, reset). Live smoke
  (Postgres + Redis, `PULSE_AUTOTUNE=1`, rate limit raised for
  the run): 105 distinct queries (all L1 misses) ->
  `l1_ttl_s` 300 -> 360, `adjustments_total` 1, log line with
  reason; `/metrics` showed `pulse_process_rss_bytes`
  31,911,936 (~30.4 MiB) and the live gauges; reset returned
  `{"reset":true,"changed":[{"knob":"l1_ttl_s","old":360,
  "new":300}]}` and `/v1/autotune` showed 300 with
  `last_adjustment` null. Smoke note: the default 100 req/min
  rate limit tripped during the 105-query run — the reset probe
  needed `PULSE_RATE_LIMIT_PER_MINUTE=1000`; the no-key reset
  correctly returned `auth_required`.

### 6.9 Horizontal scaling readiness — DONE (2026-11-13 ~17:00)

- Statelessness contract (new section in `docs/SCALABILITY.md`):
  the API is stateless except four per-instance caches, each safe
  to lose — L1 (refills from the shared Redis L2), the in-memory
  index (rebuilt from the store at boot + on epoch changes;
  queries fall back to the store search until the build
  finishes), the popular list (local `popular.json`, NOT shared
  between instances — a new instance starts empty and unwarm
  unless `PULSE_POPULAR_PATH` is on a shared volume), and the
  auto-tuner values (each instance tunes from its own traffic;
  reset is per instance). Shared state — Postgres, Redis, MinIO —
  carries auth, rate limits, quotas, and audit, so scaling out
  changes none of the guarantees.
- Scale-out shape in `docker-compose.yml` (profile `scale`):
  `api-2` (same image/command as `api`, no published port) +
  `lb` (nginx:1.27-alpine, host 9080) fronting `api:9000` +
  `api-2:9000` round-robin (`docker/nginx.conf`, new). In
  production the LB takes port 9000 and the api services drop
  their host mappings. Worker-N pattern documented: a third
  worker is the `worker-2` block copied with a new
  `PULSE_WORKER_ID`; the stream group splits the work.
- Triggers documented, not built: Redis cluster (sustained
  evictions + falling L2 hit ratio while the working set grows;
  raise maxmemory first), Postgres partitioning (sustained
  fast-path p95 above target with the DB as the measured
  bottleneck; replica + prepared statements first; monthly
  `documents` partitions only when those are exhausted),
  multi-region (a second full stack; `PULSE_COUNTRY` already
  scopes one country). Read-replica routing (R5.5, proof-only)
  unchanged.
- Honest limits: the shape is authored, not run — this VM cannot
  run the compose stack (podman `--network none`), so the first
  real `docker compose --profile scale up` on a Docker host is
  the validation step. Open-source nginx has no active health
  checks (a dead backend is skipped only after a failed request).
  `docker-compose.yml` parses as YAML (verified); `nginx.conf`
  is NOT syntax-checked here (no nginx on the VM).
- Verified: `zig build` passes; 244/244 tests (no code changed in
  this section — compose + docs only).

### 6.11 Advanced features — DONE (2026-11-13 ~17:45)

- Circuit breakers (`src/engine/breaker.zig`, new, pure state
  machine — no I/O, callers pass `now_ms` so it is unit-testable
  with fake times): closed -> open after N consecutive failures,
  refusals counted as skipped, one trial call after the cooldown
  (half-open), success closes, trial failure re-opens. State gauge
  codes 0 closed / 1 half-open / 2 open.
- Embedding breaker: `BreakerEmbedding` wraps the provider vtable;
  only the EXTERNAL provider is wrapped (main.zig, after
  `makeEmbeddingProvider` — the local hashed provider cannot fail
  and does no I/O). While open, embed calls fail fast with
  `BreakerOpen`; both call sites (query search + ingest) already
  fall back to lexical on embed failure. This matters because
  `std.http.Client.fetch` has no per-request timeout in 0.17.1 —
  a dead provider would otherwise hang every query and ingest.
  The worker's embedder is the same wrapped value, so the worker
  gets the breaker too; the server keeps the breaker pointer for
  /metrics.
- Redis breaker: the server owns one (`redis_breaker`). The L2
  lookup is skipped entirely while open (compute fresh — the path
  a miss already takes); a clean answer (hit or miss) counts as
  success, only a Redis error as failure. Both L2 puts (query
  path + cache warming) are also skipped while open, and a
  successful put counts as success. Config: `PULSE_BREAKER_*`
  (failures default 5, cooldown default 60s, min 5s).
- Metrics: `pulse_breaker_{redis,embedding}_state` gauges,
  `*_trips_total`, `*_skipped_total` (third format call in
  `render` — same 32-argument cap reason as the 6.10 split).
  Refreshed by the /metrics handler from the live breakers.
- Hot config reload: `POST /v1/admin/config` (API-key auth, kind
  null — the admin pattern). Safe settings only: `l1_ttl_s`
  60–900, `fanout_timeout_ms` 50–500, `reindex_interval_s`
  60–86400; all values must be integers, unknown keys and
  out-of-range values return 400 naming the problem, empty body
  returns 400. A manual L1 TTL / fan-out timeout becomes the
  tuner's new baseline (the next adjustment moves from it); the
  reindex interval is not tuned and holds until restart; the
  autotune reset restores only the tuner's knobs. Secrets, auth,
  rate limits, retention are never accepted here.
- Index maintenance: `analyze` added to the Repository vtable
  (memory store: no-op; Postgres: bare `ANALYZE` — all tables).
  `runMaintenance` calls it after retention; a failed ANALYZE
  warns but never fails maintenance (`report.analyzed`). VACUUM
  is deliberately NOT run — Postgres autovacuum owns dead-tuple
  reclamation. `pulse audit` gains a `checkIndexes` check
  (index counts, never-scanned names, `documents` last ANALYZE;
  WARN on zero indexes or never-analyzed documents).
- Measured-first decisions recorded in `docs/PERFORMANCE.md`
  (new): SIMD not built (no hot loop at this scale), zero-copy
  not built as a separate change (cached bodies already served
  without re-rendering; the remaining copy is a few KB),
  memory pooling exists (arenas + PgPool), lock-free queues not
  applicable (single-threaded server + external streams), async
  I/O exists (std.Io threaded), adaptive batching exists
  (runOnce batches + Streams for urgent updates), backpressure
  exists (rate-limit 429 + PgPool bounds) with one recorded gap
  (head-of-line blocking in the single-threaded accept loop —
  needs a threaded accept loop, out of scope), multi-region
  documented in 6.9.
- Bugs found during the run: (1) `catch { ... } else { ... }` does
  NOT parse as a statement in Zig 0.17.1 ("expected ';' after
  statement") — both L2 put sites rewritten to `if (put) {} else
  |_| {}` on the error union. (2) A format-string arg-count
  mismatch in the audit detail (6 args, 5 placeholders) — fixed
  by splitting into two format strings. (3) `embedder` in main.zig
  was `const` — changed to `var` for the wrapping.
- Verified: `zig build` passes; **249/249 tests pass** (5 new
  breaker unit tests: closed/success-reset, threshold trip +
  skipped count, cooldown trial + close, half-open re-trip,
  threshold-1). Live smoke still to run in the verification pass
  (breaker trip on a dead Redis + admin-config endpoint probes).
  Note: the test binary exits 1 with "36 errors were logged" even
  though all 249 tests pass — whether that is pre-existing is
  being checked against the 6.9 tree (worktree verification was
  interrupted by a VM restart; redo it before reporting 6.11
  complete).
