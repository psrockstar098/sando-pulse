# Pulse API guide (Roadmap 5.3)

Base URL: `https://sando-pulse.onrender.com` live (Render, since
2026-11-17), or `http://127.0.0.1:9000` locally, or the public URL
behind the TLS proxy in production. The full machine-readable contract is
`docs/openapi.yaml`; the Sando-specific contract is
`docs/SANDO_INTEGRATION.md`.

## Authentication

`POST /v1/query` requires an API key when one is configured.
The other two routes are public.

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
PULSE_CONSUMERS=sando:query:10000
```

Format per entry: `name:scope,scope:quota_per_day`. Scopes:

| Scope | Endpoints |
| ----- | --------- |
| `query` | `POST /v1/query` |
| `*` | `POST /v1/query` |

- Names are 1–64 chars of `[a-z0-9_-]`; anything else is `400
  invalid_consumer`. Malformed entries are skipped with a warning.
- A missing scope is `403 forbidden_scope`.
- `quota_per_day` is the consumer's daily call budget for queries.
  `0` means "use the global `PULSE_RATE_LIMIT_PER_DAY`".
  Spending the quota is `429 quota_exceeded`.


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

## The unified answer (one query, three legs)

`POST /v1/query` is the one public search surface. It fans out in
parallel to the local index, the web (SearXNG, bundled in the
all-in-one image), and the Facebook/social leg (posts the worker
already collected — Meta has no general post search, so nothing is
fetched live per query). Results are deduplicated by normalized URL,
local first then web, and every result carries `kind` (`"local"` for
RSS documents, `"social"` for Facebook posts). The response adds
one top-level `unified` object:

- `unified.web` — the web results (title, summary, URL, engine),
  in SearXNG's order, deduplicated against the local results and
  each other.
- `unified.web_complete` — whether the web leg finished before
  the answer was sent.
- `unified.sources` — one entry per leg (`local`, `web`,
  `facebook`) with `status`, `results` and `detail`. `web` is
  `ok` / `unavailable` (SearXNG not configured) / `timeout` /
  `error`; `facebook` is `configured` / `not_configured`.
- `fanout_complete` — false when a backend was still running when
  the answer was sent.

The web leg waits at most `PULSE_WEB_TIMEOUT_MS` (default 1500 ms,
minimum 50); a stuck web leg never delays the answer. Stat answers
do not fan out to the web. Existing response fields are untouched
by the fan-out. `GET /v1/websearch` was removed 2026-11-17 and the
other `/v1/*` routes were removed 2026-11-18 — one query does the
job; the debug path is the `pulse websearch` CLI.
Full detail, including the all-in-one bundling and the honest
limits: `docs/WEBSEARCH.md`.

## Roadmap 7 behaviour (no separate endpoints)

Everything in Roadmap 7 rides on `POST /v1/query` or a CLI command:

- Stat answers ride on `POST /v1/query`: a "how many schools are
  in Montserrado County?" or "what is the population of Liberia?"
  question is answered from the knowledge store and the response
  carries `stat_answer` in `enrichment` (`kind`, `sufficient`,
  `answer_text`, `value`, `unit`, `period`, `rows_counted`,
  `source`, `verified_at`, `insufficient_reason`) with
  `routing_reason: "stat_answer"`. Unknown places/facilities
  answer `sufficient: false` — never a guessed number.
- Breaking alerts: `pulse alerts` reads the `pulse:alerts` Redis
  stream newest-first. Each alert has `kind` (accident, protest,
  road_closure, emergency, announcement, community_event, unknown),
  `title`, `event_ids`, `sources`, `doc_count`, `importance`, and
  `ts`. Empty is a real answer.
- Report variants: `pulse briefing --scope weekly --kind political
  --county Lofa`. `scope` defaults to `daily`, `kind` to `general`,
  `county` unset. Variants are computed live and never cached; the
  default daily-general briefing still uses the worker-cached
  payload. Unknown scope/kind/county is a 400. The briefing carries
  `scope`, `kind`, `county`, `social_available` and `social_note`.
- Social ingestion is gated: the registry is fed only by authorized
  connector data. The Facebook connector (Graph API + webhooks,
  authorized pages only, never scraped or faked) activates when
  `PULSE_FACEBOOK_ACCESS_TOKEN` is set. Until then the unified
  query's `facebook` leg reports `not_configured`.
- Semantic search stays lexical: the external embedding provider
  has no API key and is never called live. `POST /v1/query` with a
  semantic-only question routes `deep` with
  `routing_reason: "semantic_only"` and uses the local lexical
  embedding, labelled as such.

## Trust & Intelligence Engine — removed

The Trust Engine's route surface (source profiles, monitor, evidence,
scores, rankings, history, actions, decision core, predictions,
anomalies, risk) was removed on 2026-11-18 when the API was cut to
three routes. The code is gone; the history is in git. What remains:
the 12-source registry, per-source health tracking (migration 014,
`source_health.last_new_at`, stamped by the worker), and the seeded
county/location data.


## Popular searches and freshness (Roadmap 6.4)

- The server tracks the most-asked queries internally (query text
  and a count only — no consumer, no identity) to warm the caches
  at boot. There is no public endpoint for the list.
- Every precomputed payload reports freshness: the `pulse briefing`
  payload carries `computed_at` (Unix seconds) and `stale`. The
  briefing is cached by the worker; `stale` is evaluated at serve
  time against the precompute TTL (`PULSE_PRECOMPUTE_TTL_S`, default
  3600s), so a cached briefing served hours after it was computed
  is honestly marked stale.
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
- There is no endpoint for the tuner state: restarting restores the
  configured defaults.


## Circuit breakers (Roadmap 6.11)

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
- There is no hot config reload: settings come from the environment
  at startup. A manual `l1_ttl_s` / `fanout_timeout_ms` change needs
  a restart; the tuner's adjustments are the only runtime knob moves.
- Index maintenance: `pulse maintenance` now runs a bare `ANALYZE`
  (all tables) after retention, so the planner sees the
  post-deletion shape; a failed ANALYZE warns but never fails
  maintenance. VACUUM is deliberately not run — Postgres autovacuum
  owns dead-tuple reclamation. `pulse audit` gains an `indexes`
  check: index counts, never-scanned indexes, and when `documents`
  was last ANALYZEd (WARN when there are no indexes, or when
  `documents` has never been ANALYZEd).
