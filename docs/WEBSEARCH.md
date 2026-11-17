# Web search — SearXNG (real web results for Pulse)

Pulse's own search (`POST /v1/query`) only covers the documents its
worker ingested from the registered RSS feeds. Web search adds the live
web: one call to a self-hosted [SearXNG](https://docs.searxng.org)
instance, which aggregates 70+ search engines and returns their
results as JSON. Pulse returns those results exactly as SearXNG
reported them — title, URL, content snippet, engine — with no
ranking, no verdict, and no invented fields.

## Endpoint

```
GET /v1/websearch?q=<query>&count=<n>
Authorization: Bearer <PULSE_API_KEY>
```

- Auth + rate limit: same gate as `/v1/query` (a websearch call
  spends the caller's **query** quota: 100/min + 10,000/day per key).
- `q` is required, 1–1000 chars (same bound as `/v1/query`).
- `count` is optional, 1–20, default 10. SearXNG answers one page at
  a time (10 results); asking for more than a page still returns at
  most one page.
- Response:

```json
{
  "request_id": "req-...",
  "query": "Liberia news",
  "results": [
    {
      "title": "…",
      "url": "https://…",
      "content": "…",
      "engine": "google"
    }
  ],
  "unresponsive_engines": ["bing"],
  "took_ms": 812
}
```

- `unresponsive_engines` names the upstream engines that failed for
  this query (SearXNG reports them; empty is normal).
- An empty `results` list is a valid answer — SearXNG answered,
  nothing matched — never an error.

## Status codes

| Code | Meaning |
|---|---|
| 200 | Results (possibly empty). |
| 400 | Missing/empty `q`, or `count` outside 1–20. |
| 401 | Missing/invalid API key (same as every authed endpoint). |
| 429 | Rate limit / daily quota (same as `/v1/query`). |
| 502 | SearXNG answered with an error, or answered unusably (e.g. HTML instead of JSON). |
| 503 `websearch_unavailable` | `PULSE_SEARXNG_URL` is unset — web search is not configured. |

## CLI

```sh
pulse websearch "Liberia news" [--count N] [--searxng-url <url>]
```

Prints one line per result (`title [engine] url`), plus the
unresponsive engines when any. Exit 0 = results found, 2 = no
results (a valid empty answer), 1 = SearXNG unavailable / bad
response / bad query. The URL defaults to `PULSE_SEARXNG_URL`; without
it the command refuses to run.

## Enabling it (real host, compose)

SearXNG runs as two extra services behind the `websearch` compose
profile, so the default stack is unchanged:

```sh
cp .env.example .env   # set SEARXNG_SECRET (openssl rand -hex 32);
                       # PULSE_SEARXNG_URL=http://searxng:8080 is
                       # already in .env.example
docker compose --profile websearch up -d
```

- `searxng` — image `docker.io/searxng/searxng:2026.11.15-2d500cb6b`
  (pinned dated tag, never `latest`), settings mounted from
  `docker/searxng/settings.yml`, cache in the `pulse-searxngdata`
  volume. Its port is **not** published: only the Pulse API calls it.
  Uncomment the `ports:` line in `docker-compose.yml` for local dev.
- `searxng-valkey` — `docker.io/valkey/valkey:9-alpine`, backs the
  SearXNG rate limiter.

## The JSON-format requirement

SearXNG's `search.formats` defaults to `[html]` only — a JSON request
against a default instance answers **403**. Pulse needs JSON, so the
shipped `docker/searxng/settings.yml` sets:

```yaml
search:
  formats: [html, json]
```

If you point Pulse at an existing SearXNG instance instead, make sure
its settings include `json` in `search.formats`; otherwise every
websearch call fails with 502 `websearch_bad_response` and the server
log names the setting. The same file enables the limiter
(`server.limiter: true`, backed by Valkey) and moderate safe search.
`docker/searxng/limiter.toml` passlists the compose network
(172.16.0.0/12) and localhost, so the Pulse API's own searches are
never throttled — without it, the limiter 429s the API's requests
(verified live: the default limiter blocked the first request).

## Render / all-in-one image

The all-in-one Docker image (`dominic908/sando-pulse:all-in-one-0.1.0`)
does **not** bundle SearXNG: the Render free tier is 512 MB RAM and
SearXNG + Valkey need their own memory. On Render, web search is a
second free service later (a SearXNG web service + a Valkey service,
with `PULSE_SEARXNG_URL` pointed at the SearXNG service's internal
address). On a real host it just runs in compose, as above.

## Limits, honestly

- SearXNG does **not** crawl the web itself — it aggregates engines
  (Google, Bing, DuckDuckGo, …). Those engines can rate-limit or
  CAPTCHA a self-hosted instance; when they do, the affected engines
  land in `unresponsive_engines` and results get thinner.
- Zig 0.17.1's `std.http.Client.fetch` exposes **no per-request
  timeout and no max-response-size option** (same limit as the Sando
  client in `src/sando/client.zig`). A dead or runaway SearXNG can
  stall one call; `took_ms` in the response makes a stuck upstream
  visible in the response and the logs.
- The client retries once (250 ms backoff) on a transport error or a
  5xx; a 403 is reported immediately as a bad response (it is a
  configuration problem, not a transient one).
- **Verification note (2026-11-17, this VM):** SearXNG itself ran live
  from the pinned image — `/healthz` 200, `/search?format=json` 200
  with valid SearXNG JSON (so the `json` format requirement is proven,
  not assumed), and the limiter passlist works (the API's own requests
  are never 429'd). But this VM's MITM egress proxy stopped the
  engines from returning real results here: SearXNG's curl_cffi client
  needs `outgoing.proxies` + a CA bundle for the proxy, and even with
  both set the engines timed out inside the server while identical
  direct curl_cffi calls from the same image completed in ~1.5 s. That
  is a limitation of this VM's egress, not of the integration — on a
  normal host the engines work with no proxy settings at all. The Pulse
  client + endpoint were verified end-to-end against a local stub
  returning real SearXNG-shaped JSON (results > 0, count truncation,
  400s, 503). Re-verify with real engine results on the first real
  host.
