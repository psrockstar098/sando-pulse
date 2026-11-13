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

To be filled in by 6.12: extended loadtest scenarios, measured
p50/p95/p99/p99.9 per path, RSS before/after, CPU per query.
