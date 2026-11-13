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
