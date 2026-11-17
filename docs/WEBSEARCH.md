# Web search — SearXNG, inside the unified query

Pulse's own search (`POST /v1/query`) covers the documents its
worker ingested from the registered RSS feeds. Since 2026-11-17 the
same query also fans out to the live web: one call to a self-hosted
[SearXNG](https://docs.searxng.org) instance, which aggregates
search engines and returns their results as JSON. There is **one**
public search surface — the unified `/v1/query` — and one ranked
list, with each result citing its source. Pulse returns web results
exactly as SearXNG reported them — title, URL, content snippet,
engine — with no ranking invented for them, no verdict, and no
invented fields.

## The unified answer

`POST /v1/query` keeps its existing `results` list (local documents,
fused-score order) and adds one top-level `unified` object:

```json
{
  "results": [ { "title": "…", "url": "…", "kind": "local" } ],
  "unified": {
    "web": [
      { "title": "…", "summary": "…", "url": "https://…",
        "engine": "bing",
        "source": { "name": "bing", "url": "https://…" } }
    ],
    "web_complete": true,
    "sources": [
      { "name": "local",    "status": "ok",             "results": 3, "detail": null },
      { "name": "web",      "status": "ok",             "results": 2, "detail": null },
      { "name": "facebook", "status": "not_configured", "results": 1, "detail": null }
    ]
  }
}
```

- `kind` on each local result is `"local"` for RSS documents and
  `"social"` for Facebook posts (source_id starting `facebook:`).
- `web` results are deduplicated against the local results by
  normalized URL (lowercase, no fragment, no trailing slash, no
  tracking parameters) and against each other; local results come
  first in fused order, then web results in SearXNG's order.
- `sources` is honest about each leg: `web` is `ok` / `unavailable`
  (SearXNG not configured) / `timeout` / `error`; `facebook` is
  `configured` / `not_configured`. Facebook posts are **not** fetched
  live per query — Meta has no general post search; the worker
  already collects configured pages' posts into the local index, so
  the `facebook` source only reports whether that collection is
  configured. When it is not configured, the social list is empty
  and nothing is invented.
- Stat answers do not fan out to the web (`web` status
  `"unavailable"`, detail `"not attempted for stat answers"`).
- The web leg has its own wait: `PULSE_WEB_TIMEOUT_MS` (default
  1500 ms, minimum 50). The response is sent before the fan-out
  threads are joined, so a stuck web leg delays connection cleanup,
  never client-visible latency.
- The unified answer is cached under the existing query TTL, so a
  cache hit serves the same unified answer without a fresh web
  fetch.

## The removed route

`GET /v1/websearch` existed for one day (2026-11-16) and is
**removed** as of this change. Dominic ordered fewer routes: one
query must do the job, not one route per feature. Nothing live ever
depended on it (Pulse was never deployed with it), and the unified
query is its replacement. The debug path survives as the CLI:

```sh
pulse websearch "Liberia news" [--count N] [--searxng-url <url>]
```

Prints one line per result (`title [engine] url`), plus the
unresponsive engines when any. Exit 0 = results found, 2 = no
results (a valid empty answer), 1 = SearXNG unavailable / bad
response / bad query. The URL defaults to `PULSE_SEARXNG_URL`; without
it the command refuses to run.

## Out of the box: the all-in-one image

The all-in-one Docker image (`dominic908/sando-pulse:all-in-one-0.1.0`)
**bundles SearXNG**: one `docker run` answers web searches with no
extra setup. The entrypoint starts granian (1 worker, 127.0.0.1:8080)
after Redis is up, exports `PULSE_SEARXNG_URL=http://127.0.0.1:8080`,
generates a fresh `SEARXNG_SECRET` per boot when unset, and waits up
to 60 s for `/healthz`. If SearXNG never comes up, the entrypoint
logs a warning and Pulse keeps serving local results — the web leg
reports `unavailable`/`error`, never a 500.

Only **six engines** are enabled (`docker/searxng/settings-aio.yml`,
generated from the pinned source's own defaults by
`docker/all-in-one/build.sh`): google, bing, duckduckgo, brave,
mojeek, wikipedia. The defaults enable 237 engines; each one costs
startup time, memory, and a fan-out request per query. The limiter
reuses the Redis already in the image (db 1, so it never collides
with Pulse's own keys on db 0) — **no separate Valkey process** is
started in the all-in-one image — and the shipped
`docker/searxng/limiter.toml` (copied to `/etc/searxng/` next to the
settings, where SearXNG reads it) passlists localhost, so the Pulse
API's own searches are never throttled. Without that file the
bundled limiter defaults apply, whose pass_ip list is empty, and
the API's searches get 429 (found live 2026-11-17).

Build note: the PyPI package named `searxng` is NOT the search
engine (an unrelated MCP wrapper). The engine is installed from its
GitHub repo at the pinned commit `2d500cb6b` (the same commit the
compose image pins). `build.sh` downloads the source tarball +
`requirements.txt` + `requirements-server.txt` + setuptools/wheel
into `docker/all-in-one/wheelhouse/` (gitignored staging, never
committed); the Dockerfile installs them offline with `--no-index`.
Two packaging gotchas, both baked into the Dockerfile: `setup.py`
imports `searx` (which needs `msgspec`), so the requirements are
installed first and the package itself with `--no-build-isolation`;
and Ubuntu's `ensurepip` ships no setuptools, so setuptools/wheel
come from the wheelhouse.

## Render

One service. The all-in-one image is the whole deployment — no
second SearXNG service, no Valkey service. It is live on Render
since 2026-11-17 (https://sando-pulse.onrender.com, Web Service
`sando-pulse`, Frankfurt, Free plan). The 512 MB free tier fits:
the whole container measures **341–401 MB RSS** (Pulse ~21 MB,
Postgres ~254 MB, SearXNG ~119 MB, Redis ~6 MB), leaving ~110 MB
headroom (see `docs/PERFORMANCE.md`). Free-tier facts: the service
sleeps after 15 minutes idle (a keep-alive ping hits `/v1/health`
every 10 minutes); a restart wipes the stored articles (no
persistent disk) but the worker re-fetches them from the feeds.

## Compose (dev alternative)

SearXNG + Valkey still run behind the `websearch` compose profile,
unchanged:

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
against a default instance answers **403**. Pulse needs JSON, so both
shipped settings files set:

```yaml
search:
  formats: [html, json]
```

If you point Pulse at an existing SearXNG instance instead, make sure
its settings include `json` in `search.formats`; otherwise every web
leg fails with 502 `websearch_bad_response` and the server log names
the setting. The same files enable the limiter
(`server.limiter: true`) and moderate safe search.
`docker/searxng/limiter.toml` passlists the compose network
(172.16.0.0/12) and localhost, so the Pulse API's own searches are
never throttled — without it, the limiter 429s the API's requests
(verified live: the default limiter blocked the first request).

## Facebook

The `facebook` source in `unified.sources` is `not_configured` until
`PULSE_FACEBOOK_ACCESS_TOKEN` is set (a Page token from a long-lived
user token via `GET /me/accounts` — see the Facebook connector docs).
No token, no social results, and the answer says so. When
configured, the worker ingests the page's posts and they appear in
`results` with `kind: "social"`.

## Limits, honestly

- SearXNG does **not** crawl the web itself — it aggregates engines
  (Google, Bing, DuckDuckGo, …). Those engines can rate-limit or
  CAPTCHA a self-hosted instance; when they do, the affected engines
  land in `unresponsive_engines` and results get thinner.
- Zig 0.17.1's `std.http.Client.fetch` exposes **no per-request
  timeout and no max-response-size option** (same limit as the Sando
  client in `src/sando/client.zig`). The web leg is bounded by the
  fan-out wait (`PULSE_WEB_TIMEOUT_MS`), not by the HTTP client — a
  stuck web thread delays connection cleanup, never the response.
- The client makes up to **two attempts** (1 initial + 1 retry) on
  transport errors and 5xx only, with a 250 ms backoff between
  attempts; a 403 is reported immediately as a bad response (it is
  a configuration problem, not a transient one).
- **Verification note — real engine results, proven live on
  Render (2026-11-17):** a unified `"Liberia news"` query against
  https://sando-pulse.onrender.com returned real web results via
  the Brave engine (BBC News Liberia, Al Jazeera Liberia) alongside
  real local articles. That is the first time real engine results
  have been seen end to end — the integration works on a normal
  host with no proxy settings at all.
- **Verification note — this dev VM (2026-11-17):** SearXNG itself
  ran live — first from the pinned image (`/healthz` 200,
  `/search?format=json` 200 with valid SearXNG JSON, so the `json`
  format requirement is proven, not assumed), then from the
  all-in-one packaging (venv + offline wheelhouse install + the
  generated six-engine settings, granian serving on 127.0.0.1) with
  the same shape. But this VM's MITM egress proxy stopped the
  engines from returning real results here: SearXNG's curl_cffi
  client needs `outgoing.proxies` + a CA bundle for the proxy, and
  even with both set the engines timed out inside the server while
  identical direct curl_cffi calls from the same image completed in
  ~1.5 s. That is a limitation of this VM's egress, not of the
  integration — on a normal host the engines work with no proxy
  settings at all (proven on Render, above). The Pulse client +
  unified query were verified end-to-end against a local stub
  returning real SearXNG-shaped JSON (results > 0, dedupe, count,
  400s, 503) before the Render proof existed.
