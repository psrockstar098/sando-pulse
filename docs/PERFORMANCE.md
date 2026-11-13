# Pulse performance (Roadmap 6)

Measured numbers only — no targets presented as results. Latency and
resource benchmarks land in 6.12; this file records the measurement
method and the decisions taken on measured evidence (or the lack of
it) up to that point.

## Method

- Single-threaded server, one reused arena per server (reset per
  request — see the optimization scope below); the loadtest CLI
  (`pulse loadtest`) drives sustained queries against a live server
  (Postgres + Redis) and reports p50/p95/p99/p99.9. This VM has 2
  CPUs and ~500 MB free RAM, so it cannot prove 5 ms hot paths or
  10K concurrency — the numbers here are what this machine measured,
  nothing more.
- RSS is read from `/proc/self/statm` (`pulse_process_rss_bytes` in
  `/metrics`); CPU is measured as process CPU time per 1k queries
  from the same source. Baselines are recorded before an optimization
  and after it; an optimization that does not move a measured number
  is recorded as no win, not claimed as one.

## Architecture (Roadmap 6)

### Cache layers

| Layer | Where | Bounds | TTL | Invalidation |
|---|---|---|---|---|
| L1 | In-process (`src/api/l1cache.zig`) | 512 entries / 8 MiB (`PULSE_L1_MAX_ENTRIES`, `PULSE_L1_MAX_BYTES`) | 300 s (`PULSE_L1_TTL_S`) | Tag-based on ingest; LRU eviction |
| L2 | Redis query cache (`src/api/cache.zig`) | Redis `maxmemory` 256 MB in compose (dev Redis unbounded — `pulse audit` warns) | `PULSE_QUERY_CACHE_TTL_S` | Epoch bump on ingest (all cached bodies carry the ingest epoch) |
| L3 | Postgres (the store itself) | Disk | — | — |

Keys are consumer-scoped; a cached body is stored once with empty
markers and served with the request id / path / latency spliced in
(`stampServed`), so a hit never re-renders. A miss computes once
and stores into L1 + L2.

### Index design

The in-memory inverted index (`src/engine/memindex.zig`) maps
terms to postings (doc id + score). Tokenization matches the
planner exactly; title terms weigh double; only the first 4000
bytes of a document are indexed. Bounds: 50,000 terms / 100,000
docs / 64 MiB (`PULSE_MEMINDEX_MAX_TERMS` /
`PULSE_MEMINDEX_MAX_DOCS`, bytes fixed at 64 MiB). Built from the
store at boot and rebuilt on epoch change, gated by the reindex
interval (`PULSE_REINDEX_INTERVAL_S`, default 3600 s);
`pulse reindex` rebuilds on demand. The scan behind the build
returns newest-first with an inclusive upper bound; the build
walks backward from the newest (see the 6.12 bug note — the old
forward walk capped the index at the oldest 1,000 docs).
Measured: 10,005 docs → 10,035 terms, ~89 s to build, ~32 MiB
RSS. The store search (Postgres FTS + pg_trgm + vector) is the
fallback whenever the index is thin, absent, or stale — a query
never waits for the index.

### Routing rules (`src/engine/router.zig`)

- `instant`: L1 hit only (L2 hits are stamped `instant` too —
  the response never touches the store).
- `deep`: planner intent `research` / `compare` / `historical`,
  or `strategy: deep`, or no lexical terms (semantic-only).
- `fast`: everything else.
- Every response carries `path`, measured `latency_ms`, and
  `routing_reason`. Enrichment (locations + statistics) fans out
  in parallel only when `PULSE_PARALLEL_QUERY=1` and the store is
  Postgres; otherwise it runs inline.

### Service objectives

Targets from the spec (not results — the measured numbers are in
the Benchmarks section below):

| Objective | Target |
|---|---|
| Hot path (instant, cached) | 5 ms server-side |
| Fast path | < 100 ms server-side at small scale |
| Breaking news detect + index | 5–30 s from source availability |
| Trends recalc | 15–60 s |
| Local events | 1–5 min |
| Ingest → searchable | < 1 s (measured: <1 s via the store search) |

What this VM measured instead: instant p50 42.7 ms
client-measured (0.2 ms server-side — the gap is the VM's
per-request floor, see the optimization scope); fast p50 127 ms
at 5 docs, 189 ms at 10k docs. The 5 ms hot-path target is not
met on this VM and is not claimed.

### Scaling guide

The statelessness contract and scale-out shape live in
`docs/SCALABILITY.md` (per-instance state that is safe to lose:
L1, memindex, popular list, autotuner; the guarantees live in
Postgres/Redis/MinIO). Compose ships a `scale` profile (second
API replica + nginx on host 9080). Triggers for the next step
(Redis Cluster, Postgres partitioning, multi-region) are
documented there, not built. The known scaling gap is the
single-threaded accept loop: throughput caps at ~24 calls/s on
this VM and latency scales linearly with concurrency — a
threaded accept loop is the follow-up, not part of Roadmap 6.

### Auto-tuning knobs + bounds (Roadmap 6.10)

`GET /v1/autotune` reports the live values; the tuner moves at
most one knob per 100 queries, only from measured signals, and
logs every adjustment. `POST /v1/admin/autotune/reset` restores
the configured defaults. A manual set via
`POST /v1/admin/config` becomes the tuner's new baseline.

| Knob | Default | Min | Max | Step | Signal |
|---|---|---|---|---|---|
| `l1_ttl_s` | 300 s | 60 s | 900 s | 60 s | L1 hit rate <0.5 grows, >0.9 shrinks |
| `fanout_timeout_ms` | — | 50 ms | 500 ms | 50 ms | Fan-out incomplete rate >0.2 grows |
| `max_concurrent_sources` (worker) | — | 1 | 8 | 1 | Ingest report, 1 adjustment per 10 runs |

`PULSE_PRECOMPUTE_TTL_S` is deliberately NOT auto-tuned (no
in-process signal exists for it).

## Roadmap 6.11: measured-first decisions

Each advanced feature in the spec was judged against a measurement
or an explicit reason, not built on principle:

- **SIMD — NOT built.** There is no hot loop that benefits at
  current scale: ranking scans at most ~100 candidates, tokenization
  and memindex lookups are single-digit milliseconds inside an
  85 ms query dominated by the Postgres round trip. Revisit at
  10k+ documents with a profiled hot loop, not before.
- **Zero-copy on the hot path — NOT built as a separate change.**
  The hot path already avoids re-rendering: cached bodies are stored
  once and served with only the request id / path / latency markers
  spliced in (`stampServed`). The remaining copy is a few-KB memcpy
  per hit — unmeasurable against the query cost. No win available.
- **Memory pooling for hot buffers — EXISTS, and a leak was found
  and fixed in the optimization scope below.** The per-request arena
  (now reused, reset per request) and the PgPool are the pooling
  mechanism; the churning components (L1, audit sink, popular
  tracker, memindex) allocate from `c_allocator` so their frees are
  real.
- **Lock-free / low-contention queues — NOT applicable.** The server
  is single-threaded and the worker is single-threaded; the only
  cross-thread queue is the fan-out (join-based, not a queue) and
  Redis Streams (external). There is no in-process queue to make
  lock-free.
- **Async I/O via std.Io — EXISTS.** The server and worker already
  run on the threaded I/O backend; no change.
- **Adaptive batching for ingestion — EXISTS.** The worker fetches
  due sources concurrently in each `runOnce` batch, and urgent
  updates arrive immediately through Redis Streams, never waiting
  for a batch. No change.
- **Backpressure — EXISTS in two places, one gap recorded.** The
  rate limiter sheds load with a clear 429, and the PgPool bounds
  concurrent database work (pool exhaustion fails fast instead of
  queueing unboundedly). Gap: the single-threaded accept loop means
  a slow client blocks the loop head-of-line — fixing that needs a
  threaded accept loop, an architecture change out of scope for
  6.11; recorded, not silently dropped.
- **Circuit breakers — BUILT.** The external embedder has no
  per-request timeout in Zig 0.17.1's `std.http.Client`, so a dead
  provider would hang every query and ingest; the breaker makes it
  fail fast. The Redis L2 breaker makes a dead cache cost one
  branch instead of a refused connection per request. Both are
  measured in `/metrics` (state, trips, skipped).
- **Hot config reload — BUILT.** `POST /v1/admin/config` for the
  three safe settings (L1 TTL, fan-out timeout, reindex interval).
  Secrets, auth, rate limits, and retention need a restart.
- **Automatic index maintenance — BUILT.** `pulse maintenance` runs
  a bare `ANALYZE` after retention; `pulse audit` reports index
  health (counts, never-scanned, last ANALYZE). VACUUM is
  autovacuum's job, not maintenance's.
- **Multi-region readiness — DOCUMENTED in 6.9** (statelessness
  contract, `PULSE_COUNTRY` scoping, cluster/partition triggers).

## Optimization scope (Roadmap 6, added scope — Dominic's order)

Measure first, then optimize only what moves a measured number.
All numbers below are from `pulse loadtest` (threads=1 unless
noted, 250 requests per scenario) against a live server on this VM
(Postgres + Redis, 3 documents in the store, API key on).

### Baseline (before any optimization)

| Scenario | query p50 | query p95 | query p99 | query p99.9 | RSS delta | CPU per 1k queries |
|---|---|---|---|---|---|---|
| 250 distinct queries (fast path) | 126.9 ms | 129.4 ms | 133.8 ms | 186.2 ms | **+41.4 MiB** (10.7 → 52.1) | 9120 ms |
| 250 same query (instant path) | 42.7 ms | 43.9 ms | 44.7 ms | 128.7 ms | **+6.3 MiB** (52.1 → 58.5) | 1480 ms |
| health (either run) | 42.1 ms | 43.1 ms | 44.7 ms | 46.0 ms | — | — |

Idle RSS at boot: 11.2 MiB. The memory numbers are the finding:
the server retained ~170 KB per fresh query and ~25 KB per
cache-hit query — unbounded growth, a production OOM, not a slow
leak.

### Root cause 1 — fresh arena per request, parent is a process arena

`handleRequest` created a new `ArenaAllocator` from the server's
allocator on every request. The server's allocator is the
process-lifetime arena (`init.arena` in main.zig), whose `free` is
a no-op — so every request's arena backing buffers were allocated
fresh and never reclaimed. **Fix:** one arena per server
(`Server.req_arena`), reset with `.retain_capacity` at the start
of every request (and every cache-warming query). Safe because the
server is single-threaded and nothing arena-allocated outlives
the request: L1/L2 puts dupe with their own allocators, the audit
sink consumes its record synchronously, the memindex owns its
storage (the request arena only holds its build temporaries).

### Root cause 2 — bounded components whose frees were no-ops

The L1, audit sink, popular tracker, and memindex are all
*logically* bounded (L1: 512 entries / 8 MiB; popular: 1000
tracked; memindex: 50k terms / 100k docs / 64 MiB) — but they
allocated from the process arena, so every eviction/free retained
its bytes. The L1's bound held for *live* entries while RSS grew
~6 KB per evicted entry. **Fix:** the four components allocate
from `std.heap.c_allocator` (malloc/free — real frees, no leak
report) in main.zig. The process arena stays for everything else
(it is deliberate: a GPA would report every never-freed
lifetime allocation as a leak in debug builds).

### The crash the fix surfaced — cross-allocator free in the popular tracker

After the c_allocator change the server aborted mid-benchmark
with `munmap_chunk(): invalid pointer`. Cause: `PopularSearches
.record` allocated the normalised key with a caller-passed
allocator (the process arena) while `evictLowest`/`deinit` freed
keys with the map's allocator (now c_allocator). It only fired
once tracking crossed 1000 queries — the first eviction. **Fix:**
`record` allocates the key with the map's own allocator
(`self.counts.allocator`); the caller-passed parameter is gone
so no caller can pass the wrong allocator again. The L1 and
memindex were audited for the same pattern: both dupe everything
they keep with their own allocator (verified by reading
`addDocument` and `put`).

### Post-fix numbers (same scenarios, fresh server)

| Scenario | query p50 | query p95 | query p99 | query p99.9 | RSS delta | CPU per 1k queries |
|---|---|---|---|---|---|---|
| 250 distinct (fast) | 126.3–127.8 ms | 128.6–133.5 ms | 130.1–145.2 ms | 131.3–171.6 ms | +1.0 / +1.1 / +0.5 / −0.3 / +0.8 MiB per batch | 8000–8880 ms |
| 250 same (instant) | 42.8 ms | 44.7 ms | 68.7 ms | 128.8 ms | +0.1 MiB | 1600 ms |

5 fresh distinct batches (1,250 queries): 1,250/1,250 ok, 0
errors, 0 crashes. RSS 12.8 → 16.0 MiB total; the per-batch
deltas are L1 fill from empty (live L1 bytes 0.94 MiB) then flat
once full — batch 4 went **negative** (−0.3 MiB, malloc returning
pages). L1 ended at 512 entries (at the bound), 1,017,669 bytes
(well under the 8 MiB cap), **748 evictions** with no growth.
**Latency: no change** (fast ~127 ms, instant ~43 ms — the arena
change does not affect service time). **CPU: no measurable change**
(8000–8880 vs 9120 baseline, inside run-to-run noise) — recorded
as no win, not claimed as one.

### The 42 ms floor — environment, not Pulse code

Every request, including a trivial health check, takes ~42 ms
end to end on this VM while the server burns <1 ms CPU per
request and the instant-path handler reports 0.165 ms. curl
timing: connect 0.2 ms, first byte 41.7 ms. A trivial Python
HTTP server on the same VM answers in 2–3 ms, so the loopback
stack is fine. The delay is between connect and first byte,
i.e. inside the server's socket path: `std.Io.Threaded` dispatches
each socket op (accept/read/write/close) to a worker thread, and
on this throttled VM (1.5 shared CPUs) each dispatch costs ~10 ms
of wakeup/scheduling latency. Evidence: threads=4 shows 4× the
floor (health p50 167 ms) — the single-threaded accept loop
serialises the four clients' requests. This is a property of the
std implementation on this VM, not a Pulse code cost, and it is
not fixed here (Pulse cannot patch std). Re-measure on real
hardware before treating any absolute latency as a Pulse number.
The fast-path service time (~127 ms, dominated by the Postgres
round trip + enrichment) is the number that transfers.

### Bounds audit (all live sizes bounded, frees now real)

L1 512 entries / 8 MiB (measured live: 512 / 1.0 MiB); memindex
50k terms / 100k docs / 64 MiB; PgPool bounded (pool exhaustion
fails fast); query cache Redis maxmemory 256 MB in compose (dev
Redis unbounded — `pulse audit` warns, expected); popular 1000
tracked; fan-out bounded tasks. The per-request arena is bounded
by the largest single request (retained buffers, ~170 KB peak
for a fast-path query).

## Benchmarks (Roadmap 6.12)

All runs are `pulse loadtest` against a live server on this VM
(Postgres + Redis, API key on), threads=1 unless noted, 250
requests per scenario unless noted. The store held 3–5 documents
unless a scenario says 10,005. Latency is client-measured (it
includes the ~42 ms per-request floor documented in the
optimization scope — the server's own `latency_ms` is lower).

### Latency by path (3–5 documents)

| Scenario | query p50 | p95 | p99 | p99.9 | CPU / 1k queries | RSS delta |
|---|---|---|---|---|---|---|
| fast, distinct (uncached) | 126.9 ms | 129.4 ms | 133.8 ms | 186.2 ms | 9120 ms | +41.4 MiB pre-fix, +1.0 MiB post-fix |
| instant, same query (cached) | 42.7 ms | 43.9 ms | 44.7 ms | 128.7 ms | 1480 ms | +0.1 MiB post-fix |
| deep, distinct (research intent) | 127.1 ms | 129.3 ms | 132.3 ms | 138.4 ms | 9920 ms | +1.1 MiB |
| health | 42.1 ms | 43.1 ms | 44.7 ms | 46.0 ms | — | — |

Deep ≈ fast at this scale: the deep path's extra work (whole
candidate set + fuzzy second pass) is trivial over 5 documents.
The deep query used was "research the causes of fuel shortages,
deep dive analysis" (routing `intent_deep`); a "compare fuel
prices in Monrovia and Buchanan" query routes **fast**, not deep,
because the two place names outscore the compare intent in the
classifier (local +3 vs compare +1) — classifier behaviour, not
a router bug.

### Latency by path (10,005 documents)

| Scenario | query p50 | p95 | p99 | p99.9 | CPU / 1k queries | RSS delta |
|---|---|---|---|---|---|---|
| fast, distinct | 189.1 ms | 218.2 ms | 239.1 ms | 287.9 ms | 56,840 ms | +2.6 MiB |
| instant, same query | 42.8 ms | 45.9 ms | 57.8 ms | 191.9 ms | 2000 ms | −0.3 MiB |
| deep, distinct | 151.7 ms | 202.1 ms | 257.2 ms | 262.6 ms | 9520 ms | −0.1 MiB |
| fast, limit=20, distinct | 186.3 ms | 198.5 ms | 260.9 ms | 260.9 ms | 56,700 ms | +2.5 MiB |

At 10k docs the fast path costs 7× the CPU of the 5-doc store
(56,840 vs 9120 ms/1k) — the Postgres search + ranking over
10k rows dominates. The deep path is *cheaper* than fast here
(9520 ms/1k): it shortlists from the in-memory index first and
only falls back to the store search when thin, while fast always
runs the Postgres search. Instant is unchanged by store size
(cache hits never touch the store). Limit 10 vs 20 costs the
same — the search already fetches 100 candidates and ranks them;
rendering 20 vs 10 results is trivial.

### Scale

- Index build (`pulse reindex`, 10,005 docs): **docs_added
  10,005 of 10,005**, 10,035 terms, wall time ~89 s (the
  in-app `duration_ms` reports 0 — a pre-existing reporting bug:
  both timestamps are captured before the build; the real time
  is measured externally). Boot build over the same store: ~90 s
  before the server listens.
- Idle RSS: 12.9 MiB (5 docs) → **45.2 MiB (10,005 docs)** — the
  10k-doc memindex costs ~32 MiB.
- The 1M / 10M+ indexed-record milestones are **not tested**:
  10k is what this VM ran; 1M would take ~2.5 hours to index at
  the measured 89 s / 10k rate and needs a real host. Not a
  capacity claim.
- The build exposed a real bug (fixed in this section, below):
  the index silently capped at the oldest 1,000 documents.

### Concurrency

| Threads | requests | ok | errors | query p50 | throughput |
|---|---|---|---|---|---|
| 1 | 250 | 250 | 0 | 42.8 ms (instant) / 126.9 ms (fast) | 11.8–23.5 calls/s |
| 4 | 250 | 1000 | 0 | 167.9 ms | 23.8 calls/s |
| 50 | 20 | 1000 | 0 | 2095.2 ms | 23.9 calls/s |

0 errors at 50-way concurrency — the server is correct under
load — but throughput caps at ~24 calls/s and latency scales
linearly with concurrency (50 × the 42 ms floor): the
single-threaded accept loop serialises everything. The 1K and
10K concurrency milestones are **not reached here** (at 1K
threads the queue would be ~42 s per request, past the
loadtest's 10 s timeout) — they need a real host *and* the
threaded accept loop recorded as the head-of-line gap.

### Simultaneous ingest + search

10 ingests (201, ~337 ms each) during a 250-request instant
loadtest: 250/250 ok, 0 errors, query p50 unchanged (42.8 ms),
but **p99 44.7 → 351.8 ms** — each ingest blocks the
single-threaded accept loop for ~337 ms, so queries queueing
behind one wait. Same head-of-line cause as the concurrency
numbers.

### Interruptions

- **Redis killed mid-run (6.11 smoke):** queries keep serving
  200 compute-fresh; breaker trips (state 2, trips 1, skipped
  5); after restart + cooldown the trial reconnects, the
  breaker closes (state 0), and a fresh-L1 server serves the
  same query as `instant l2_hit`.
- **Postgres killed mid-run:** queries fail fast with HTTP 500
  `search_failed` in ~60 ms (no hang). 67 of 250 queries failed
  during the ~11 s outage; after `service postgresql start`
  the server recovers **without a restart** (health ok,
  subsequent queries succeed). A repeat query would have been
  served from L1/L2 despite the outage — the distinct-query
  scenario is the worst case.

### Freshness

Ingest → searchable via `/v1/query`: **<1 s** (the doc was
found on the first query after the 201). The store search is
the fallback, so freshness does not wait for the memindex —
but the memindex itself only picks the doc up at the next
epoch-triggered rebuild (reindex interval, 3600 s default).
Freshness objectives from the spec (breaking news 5–30 s,
trends 15–60 s, local events 1–5 min) are targets: the
ingest→searchable path meets the breaking-news bound; the
memindex lag (up to 1 h) is the honest gap for index-backed
queries, and the worker cadence that feeds ingest is
configurable per source (not measured end-to-end here — no
live source was connected during the benchmarks).

### Cache hit ratio, DB connections

- A mixed run (250 instant + 250 distinct + 100 limit=20):
  L1 hits dominate the repeated queries (instant path);
  distinct queries are L1+L2 misses by construction. The
  ratio is scenario-defined, not a single number — the
  `/metrics` counters (`pulse_l1_cache_hits_total`,
  `pulse_queries_cache_hits_total` and their misses) are the
  source of truth per run.
- Postgres connections during a run: **~3 server connections**
  (pool size 1 by default — `PULSE_PG_POOL_SIZE` — plus the
  audit sink's client). The pool is the single query
  connection; the server is effectively single-connection for
  queries, matching the single-threaded loop.

### Bugs found by the benchmarks (fixed here)

1. **Memindex capped at the oldest 1,000 documents (6.5 bug).**
   `scanDocuments(before_ts)` is an *upper* bound (`fetched_at
   < cut`, ASC), but `buildFromRepo` paginated as if it were a
   lower bound (`before_ts = newest + 1`) — it re-read the same
   oldest 1,000 docs and stopped. The 10k scale test caught it:
   `reindex` reported `docs_added=1000`. Fix: the scan now
   returns newest-first with an *inclusive* bound, and the
   build walks backward from the newest (boundary second
   re-scanned, deduped by the seen-set). Verified: `reindex`
   over 10,005 docs reports `docs_added=10005`, and a new
   regression test builds 2,500 docs in a memory store and
   asserts all are indexed. Side effects of the DESC order,
   all audited: trends now scans the newest 5,000 (more correct
   for a recent window); retention archives/deletes the newest
   1,000 under the cutoff per pass (the pair stays consistent
   and converges); duplicates/aggregates sample the newest
   `limit` docs instead of the oldest. Known edge: if more
   than one batch (1,000) of documents share one `fetched_at`
   second, a full batch of already-seen docs can end the walk
   early and the rest of that second is skipped — a
   (timestamp, id) cursor would close it; recorded, not fixed
   here.
2. **`options.limit` was a no-op (pre-existing API bug).**
   The limit was validated (1..20) and hashed into the cache
   key, but `computeQuery` never passed it to the search — the
   response always rendered 10 results (`top_n` and `shown`
   were both hardcoded 10). Fix: the limit threads from
   `qr.limit` through `computeQuery` → `SearchOptions.limit`
   → `top_n` → `buildQueryResponse(limit)`, and
   `outcome.results` now carries only the top-N docs. Verified
   live: limit=20 returns 20 results, limit=5 returns 5, and
   the two are distinct cache keys. Two new tests
   (`searchAndRank honours options.limit`,
   `buildQueryResponse renders exactly options.limit results`).
   Found alongside it: the loadtest sent a top-level
   `"limit"` field, which the parser ignores (the API reads
   `options.limit`) — the loadtest now sends the documented
   shape, and `--limit` validates 1..20 client-side.
3. **`reindex`/`buildFromRepo` duration reporting:** the
   in-app `duration_ms` is always 0 (both timestamps are
   captured before the build). The real build time (~89 s /
   10k docs) is measured externally. Not fixed here — a
   reporting nit, recorded.

