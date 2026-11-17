# Sando ↔ Pulse integration contract (Roadmap 5.2)

Pulse-side contract for Sando. This document is the agreement: Sando
implements a client against it (the reference client in
`src/sando/client.zig` already does), and Pulse guarantees the
behaviour below across API v1.

> **Pulse never touches Sando's repo.** Everything on this page lives
> on Pulse's side: the client, the mock CLI, and this contract.

## Endpoint

```
POST {PULSE_URL}/v1/query
Authorization: Bearer <PULSE_API_KEY>
X-Pulse-Consumer: sando
Content-Type: application/json
Accept: application/json
```

`PULSE_URL` defaults to `http://127.0.0.1:9000` on a local install. In
production it is the public Pulse URL: https://sando-pulse.onrender.com
(live on Render since 2026-11-17).

## Request

```json
{
  "query": "fuel shortage in Monrovia (in Montserrado county)",
  "options": { "limit": 5 },
  "context": { "county": "Montserrado", "language": "koloqua" }
}
```

- `query` (required): 1–1000 chars, the user's question.
- `options.limit` (optional, default 10, max 20): how many cited
  results to return. Sando uses 5.
- `context` (optional, ignored by the server today): passed through
  for forward compatibility. **County context works today by folding
  it into the query text** — the planner extracts county names from
  the question, so `"... (in Montserrado county)"` is what makes a
  county-scoped answer happen. `language` is informational only until
  a future server version uses it.

Unknown top-level fields are ignored, so sending `context` is safe.

## Response (200)

```json
{
  "query": "fuel shortage in Monrovia (in Montserrado county)",
  "answer": "Fuel queues grew across Monrovia this week...",
  "sufficient": true,
  "insufficient_reason": null,
  "confidence": 0.65,
  "results": [
    {
      "title": "Fuel queues grow at Monrovia stations",
      "summary": "Long queues formed at...",
      "url": "https://liberianobserver.com/...",
      "source": { "name": "Daily Observer", "url": "https://liberianobserver.com" },
      "published_at": "2026-11-12T09:14:00Z",
      "score": 0.81
    }
  ],
  "events": [],
  "timeline": [],
  "query_plan": { "intent": "local", "topics": ["energy"], "...": "..." },
  "meta": { "request_id": "req-...", "results_count": 3, "sources_checked": 5, "generated_at": "2026-11-13T03:00:00Z" }
}
```

- `sufficient` is the field Sando must branch on. `true` means Pulse
  found evidence and `answer` is an extractive summary grounded in
  `results`. `false` means **no evidence** — `answer` is null and
  `insufficient_reason` explains why (`no_documents_matched`,
  `insufficient_coverage`, ...). A `false` answer is a valid response,
  not an error: Sando says it does not know, and never fills the gap.
- `confidence` is 0–1. Sando should show it, or a qualitative label
  derived from it — never inflate it.
- `results` are the citations. Sando renders each with its title,
  source name and URL. The answer text is built only from these
  documents; nothing in it comes from anywhere else. Each result
  carries `kind` (`"local"` for RSS documents, `"social"` for
  Facebook posts), and the response adds a top-level `unified`
  object: `unified.web` (the web results, in SearXNG's order),
  `unified.web_complete`, and `unified.sources` (one entry per leg
  — `local`, `web`, `facebook` — with `status`, `results` and
  `detail`). Sando may show web citations the same way as local
  ones; when `facebook` is `not_configured` there are no social
  results to show. See `docs/WEBSEARCH.md` for the full shape.

## Errors

| Status | Meaning | Sando behaviour |
| ------ | ------- | --------------- |
| 400 | Bad question (empty, >1000 chars, bad limit) | Fix the request; do not retry |
| 401 | Bad or missing API key, or unknown consumer (`X-Pulse-Consumer`) | Show a configuration error; do not retry |
| 403 | Consumer lacks the `query` scope | Show a configuration error; do not retry |
| 429 | Rate limit or daily quota spent | Back off and retry later; show "busy, try again" |
| 500/502/503/504 | Pulse error | Retry with backoff, then show "news service unavailable" |
| No response | Pulse down / network down | Same as 5xx |

The reference client retries transport errors, 5xx and 429 up to 3
attempts with linear backoff (250ms × attempt) and returns a typed
error (`PulseUnavailable`, `Unauthorized`, `QuotaExceeded`) when the
retries are spent. **On any of those errors Sando shows a fallback
line and never a fabricated answer.**

Timeout: Zig 0.17.1's `std.http.Client.fetch` has no per-request
timeout option, so the reference client cannot enforce one. If Sando
needs a hard bound, run the call on a worker thread with a watchdog.

## Consumer setup

Register Sando as a consumer so its quota is separate from other
callers:

```
PULSE_CONSUMERS=sando:query,admin:10000
```

That gives the `sando` consumer the `query` and `admin` scopes and a
10,000-calls-per-day quota (0 = the global `PULSE_RATE_LIMIT_PER_DAY`
instead). Usage is visible at `GET /v1/usage` (admin scope) and every
call is written to the audit log (`audit_log` table / JSONL file).

## Testing the integration

```sh
# 1. Start Pulse (migrations run at boot; audit_log table included).
./zig-out/bin/pulse serve

# 2. Ask through the mock Sando client (exit 0 = sufficient answer,
#    exit 2 = valid insufficient answer, exit 1 = error).
./zig-out/bin/pulse mock-sando "fuel shortage in Monrovia" --county Montserrado

# 3. A question with no evidence should exit 2 with a refusal reason.
./zig-out/bin/pulse mock-sando "quantum computing in Lofa county"
```

Expected live behaviour (verified 2026-11-13): the first call returns
`sufficient: true` with real citations once documents are ingested;
the second returns `sufficient: false` with
`insufficient_reason: no_documents_matched`. On an empty store both
return `false` — that is the correct refusal, not a failure.

Re-verified live on Render 2026-11-17: a unified `"Liberia news"`
query against https://sando-pulse.onrender.com returned 10 results
— real local articles plus real web results via the Brave engine
(BBC News Liberia, Al Jazeera Liberia) — with the `unified` object
citing each leg. The Facebook leg reported `not_configured` (no
Page token set yet) and no social results were invented.

## Versioning

- All JSON responses carry `x-pulse-api-version: 1`; `/v1/health`
  carries `"api_version": "1"`.
- v1 is additive-only: new fields may appear, existing fields never
  change meaning or disappear without a new major version.
- Breaking changes, if ever needed, ship as `/v2/...` alongside v1.
