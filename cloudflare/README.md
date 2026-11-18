# Cloudflare edge proxy for Sando Pulse

A free Cloudflare Worker that sits in front of the Pulse API on Render
(`https://sando-pulse.onrender.com`) and answers on a `workers.dev`
address. No custom domain, no card, $0 on the Workers free tier
(100,000 requests/day).

## What it does

- Proxies every request to the Render origin, forwarding method, headers
  (including `Authorization: Bearer <key>`), and body untouched.
- Edge-caches safe GETs for a short time: `/v1/health` (60s),
  `/v1/sources` (300s). Repeated reads are served from the edge without
  waking Render.
- `POST /v1/query` and everything else always go live to the origin.
- Adds an `x-pulse-edge: cloudflare-worker` response header so you can
  tell a proxied answer from a direct one.

## Deploy

Dashboard (no CLI needed): sign in at https://dash.cloudflare.com →
Workers & Pages → Create Worker → paste `worker.js` → Deploy. The Worker
name is `sando-pulse`; the public URL is
`https://sando-pulse.<your-subdomain>.workers.dev`.

CLI: `wrangler deploy` with `worker.js` as main (needs a Cloudflare API
token with Workers edit scope).

## Verify live

```sh
curl -s https://sando-pulse.<your-subdomain>.workers.dev/v1/health
curl -s -X POST https://sando-pulse.<your-subdomain>.workers.dev/v1/query \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <key>' \
  -d '{"query": "Liberia news"}'
```

Both must return what the Render origin returns. The `/v1/health` answer
may be up to 60 seconds stale by design.
