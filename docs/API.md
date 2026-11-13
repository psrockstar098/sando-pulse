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
