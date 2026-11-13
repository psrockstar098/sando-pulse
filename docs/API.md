# Pulse API guide (Roadmap 5.3)

Base URL: `http://127.0.0.1:9000` locally, or the public URL behind the
TLS proxy in production. The full machine-readable contract is
`docs/openapi.yaml`; the Sando-specific contract is
`docs/SANDO_INTEGRATION.md`.

## Authentication

`POST /v1/query`, `POST /v1/ingest` and `GET /v1/usage` require an API
key. Every other route is public (read-only intelligence endpoints).

```
Authorization: Bearer <PULSE_API_KEY>
X-Pulse-Consumer: sando
```

- Generate a key with `./zig-out/bin/pulse keygen` and set it as
  `PULSE_API_KEY`. The key is a random 32-byte hex string; never commit
  it, never put it in a URL, never log it.
- When **no** key is configured the server runs in open dev mode and
  the header is not required. `pulse audit` fails this state, and it
  must never be used in production.
- `X-Pulse-Consumer` names the caller. When `PULSE_CONSUMERS` is set,
  an unknown name is rejected with `401 unknown_consumer`; when it is
  unset, every caller is the implicit `default` consumer.

## Consumers, scopes and quotas

Register consumers in `PULSE_CONSUMERS` (semicolon-separated):

```
PULSE_CONSUMERS=sando:query,admin:10000;ingest-bot:ingest:5000
```

Format per entry: `name:scope,scope:quota_per_day`. Scopes:

| Scope | Endpoints |
| ----- | --------- |
| `query` | `POST /v1/query` |
| `ingest` | `POST /v1/ingest` |
| `admin` | `GET /v1/usage` |
| `*` | all three |

- Names are 1–64 chars of `[a-z0-9_-]`; anything else is `400
  invalid_consumer`. Malformed entries are skipped with a warning.
- A missing scope is `403 forbidden_scope`.
- `quota_per_day` is the consumer's daily call budget across query +
  ingest. `0` means "use the global `PULSE_RATE_LIMIT_PER_DAY`".
  Spending the quota is `429 quota_exceeded`.
- `GET /v1/usage` (admin scope) shows today's counts, quotas and
  remaining budget per consumer; `?consumer=<name>` filters to one.

## Rate limits

Per presented API key (each key gets its own budget, so rotation does
not share a bucket with the old key):

- `PULSE_RATE_LIMIT_PER_MINUTE` (default 100)
- `PULSE_RATE_LIMIT_PER_DAY` (default 10000, also the fallback quota)

Exceeding either is `429 rate_limited` with a `Retry-After` header.
The response header `x-pulse-cached: true/false` on `/v1/query` tells
whether the answer came from the Redis query cache.

## Error codes

Every error uses one envelope (HTTP status + JSON body):

```json
{ "error": "rate_limited", "code": "rate_limited", "message": "Rate limit exceeded", "request_id": "req-..." }
```

| Code | Status | Meaning |
| ---- | ------ | ------- |
| `invalid_request` | 400 | Malformed body or parameters |
| `invalid_consumer` | 400 | Bad `X-Pulse-Consumer` name |
| `invalid_window` | 400 | `window` not `24h`, `7d` or `30d` |
| `auth_required` | 401 | Missing `Authorization` header |
| `auth_invalid` | 401 | Wrong API key |
| `unknown_consumer` | 401 | Consumer not registered |
| `forbidden_scope` | 403 | Consumer lacks the scope |
| `method_not_allowed` | 405 | Wrong method on a known route |
| `not_found` | 404 | Unknown route, or unknown event id |
| `rate_limited` | 429 | Per-minute/per-day limit |
| `quota_exceeded` | 429 | Consumer daily quota spent |
| `facebook_unavailable` / `webhooks_unavailable` | 503 | Facebook connector not configured |
| `*_failed` (e.g. `search_failed`) | 500 | Pulse-side failure |

Include the `request_id` when reporting a problem — it is in every
response body and in the `x-request-id` header, and it appears in the
audit log.

## Versioning

- Current API version is **1**: every JSON response carries the
  `x-pulse-api-version: 1` header, and `/v1/health` carries
  `"api_version": "1"`.
- v1 is **additive-only**: new fields may appear, existing fields
  never change meaning or disappear.
- A breaking change, if ever needed, ships as `/v2/...` alongside v1
  — v1 is not removed without notice.

## Honest answers

`POST /v1/query` returns `sufficient: false` with
`insufficient_reason` (e.g. `no_documents_matched`) when Pulse has no
evidence. That is a valid 200 response, not an error — treat it as "I
don't know" and never fill the gap with invented content. The answer
text is extractive: it is built only from the cited `results`.

## Query response fields (Roadmap 6.1, 6.12)

Every `POST /v1/query` 200 carries, alongside the answer:

- `path` — the execution path that served this response:
  `instant` (L1/L2 cache hit only — no store work),
  `fast` (memindex shortlist + store search, the default), or
  `deep` (research/compare/historical intents: whole candidate
  set + fuzzy second pass).
- `latency_ms` — measured server-side latency (fractional). This
  is the handler's time only; client-measured latency is higher
  (connection setup + the per-request floor on the dev VM — see
  `docs/PERFORMANCE.md`).
- `routing_reason` — why the router chose the path
  (`l1_hit`, `l2_hit`, `default_fast`, `intent_deep`,
  `strategy_deep`, `semantic_only`).
- `options.limit` (request, 1–20, default 10) controls how many
  results the response carries. It was a no-op before Roadmap
  6.12 (always 10 results); since 6.12 it threads through the
  search and the renderer — limit=20 returns 20 results,
  limit=5 returns 5, and the two are distinct cache keys. A
  top-level `"limit"` field is ignored: send it under
  `"options"` (`{"query": "...", "options": {"limit": 20}}`).
  Outside 1–20 the request is a 400.

## Popular searches and freshness (Roadmap 6.4)

- `GET /v1/popular?limit=N` returns the most-asked queries,
  most-asked first, with a count each plus `tracked` (how many
  distinct queries are tracked). Only the query text and a count are
  ever recorded or exposed — no consumer, no identity.
- Every precomputed payload reports freshness: `/v1/trends` and
  `/v1/briefing` carry `computed_at` (Unix seconds) and `stale`.
  Trends are computed live from a store scan on every request, so
  `stale` is always false there. The briefing is cached by the worker;
  `stale` is evaluated at serve time against the precompute TTL
  (`PULSE_PRECOMPUTE_TTL_S`, default 3600s), so a cached briefing
  served hours after it was computed is honestly marked stale.
- At boot the server warms the L1 + L2 caches by running the most
  popular queries through the same pipeline a cache miss uses, so a
  warmed answer is byte-identical to a freshly computed one. The
  warmed queries are the top `PULSE_POPULAR_WARM_N` (default 10) from
  the persisted popular list. Warming never fails the boot.

## Auto-tuning (Roadmap 6.10)

- Disabled by default; `PULSE_AUTOTUNE=1` enables it. The tuner
  adjusts only safe knobs, one step at a time, within documented
  bounds, and logs every adjustment (old -> new + reason). It never
  touches correctness behaviour, auth, or retention.
- Knobs and signals: L1 TTL (60–900s, step 60s) from the L1 hit rate
  (< 0.5 grows it, > 0.9 shrinks it); fan-out timeout (50–500ms, step
  50ms) from the enrichment incomplete rate (> 0.2 grows it, zero
  stragglers over 50 fan-outs shrinks it); max concurrent sources
  (1–8, worker-side) from the ingest run report (source errors shed
  concurrency, slow but clean fetches add it). At most one
  server-side adjustment per 100 queries, one worker-side adjustment
  per 10 runs; a knob already at its bound stays put. Signals need a
  minimum sample (20 L1 events, 10 fan-outs) before anything moves.
- The precompute interval (`PULSE_PRECOMPUTE_TTL_S`) is NOT
  auto-tuned: there is no in-process signal for briefing freshness
  cost, so it stays manual-only.
- `GET /v1/autotune` (public) reports enabled, the live knob values,
  `adjustments_total`, and the last adjustment with its reason.
  `POST /v1/admin/autotune/reset` (API-key auth) restores the
  configured defaults and applies them to the live knobs; it returns
  the list of values that actually changed. Restarting also restores
  the defaults.
- `/metrics` carries `pulse_autotune_adjustments_total`, gauges for
  the live knob values, `pulse_fanout_total` /
  `pulse_fanout_incomplete_total`, and `pulse_process_rss_bytes`
  (process RSS from /proc/self/statm; 0 when unreported).

## Circuit breakers and hot config reload (Roadmap 6.11)

- Two circuit breakers stop the server hammering a dead dependency;
  both fall back to the degraded path that already exists, so an open
  breaker never changes what a query returns — only how much work is
  wasted getting there. A breaker trips open after N consecutive
  failures (default 5, `PULSE_BREAKER_*_FAILURES`), refuses calls
  while open (counted as skipped), and allows one trial call after
  the cooldown (default 60s, `PULSE_BREAKER_*_COOLDOWN_S`); a trial
  success closes it, a trial failure re-opens it.
- Embedding breaker: guards the external HTTP embedder — there is no
  per-request timeout in Zig 0.17.1's `std.http.Client`, so a dead
  provider would hang every query and every ingest. While open, embed
  calls fail fast with `BreakerOpen` and both call sites fall back to
  lexical (the behaviour they already had on embed failure). The
  local hashed provider is never wrapped: it cannot fail and does no
  I/O. Only `PULSE_EMBEDDING_PROVIDER=external` gets a breaker.
- Redis breaker: guards the L2 cache lookups and puts. While open,
  the query path skips L2 entirely and computes fresh (the path a
  miss already takes); a clean answer — hit or miss — counts as a
  breaker success, only a Redis error counts as a failure.
- `/metrics` carries `pulse_breaker_redis_state` /
  `pulse_breaker_embedding_state` (0 closed, 1 half-open, 2 open),
  `pulse_breaker_*_trips_total`, and
  `pulse_breaker_*_skipped_total`.
- `POST /v1/admin/config` (API-key auth) hot-reloads SAFE settings
  only: `l1_ttl_s` (60–900), `fanout_timeout_ms` (50–500),
  `reindex_interval_s` (60–86400). All values must be integers;
  unknown keys and out-of-range values are rejected with 400.
  Secrets, auth, rate limits, and retention are never accepted here
  — they need a restart. A manual `l1_ttl_s` / `fanout_timeout_ms`
  becomes the tuner's new baseline (the next auto-tuning adjustment
  moves from it); to hold a manual value, disable autotune
  (`PULSE_AUTOTUNE=0`). The reindex interval is not tuned, so it
  holds until the next restart. `POST /v1/admin/autotune/reset`
  restores only the tuner's knobs, not the reindex interval.
- Index maintenance: `pulse maintenance` now runs a bare `ANALYZE`
  (all tables) after retention, so the planner sees the
  post-deletion shape; a failed ANALYZE warns but never fails
  maintenance. VACUUM is deliberately not run — Postgres autovacuum
  owns dead-tuple reclamation. `pulse audit` gains an `indexes`
  check: index counts, never-scanned indexes, and when `documents`
  was last ANALYZEd (WARN when there are no indexes, or when
  `documents` has never been ANALYZEd).
