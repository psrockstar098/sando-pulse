# Pulse performance (Roadmap 6)

Measured numbers only — no targets presented as results. Latency and
resource benchmarks land in 6.12; this file records the measurement
method and the decisions taken on measured evidence (or the lack of
it) up to that point.

## Method

- Single-threaded server, one arena per request; the loadtest CLI
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
- **Memory pooling for hot buffers — EXISTS.** The per-request arena
  (freed as a whole) and the PgPool are the pooling mechanism; no
  new allocator work was needed.
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

## Benchmarks (Roadmap 6.12)

To be filled in by 6.12: extended loadtest scenarios, measured
p50/p95/p99/p99.9 per path, RSS before/after, CPU per query.
