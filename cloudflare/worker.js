// Sando Pulse edge proxy — Cloudflare Worker (free tier).
//
// What it does: sits in front of the Pulse API on Render and answers as
// https://<name>.<subdomain>.workers.dev. Safe GET endpoints are cached at
// the Cloudflare edge for a short time so repeated reads don't wake the
// Render service; everything else (including POST /v1/query) passes
// straight through to the origin, live.
//
// No custom domain needed — the workers.dev address is the public URL.
// No secrets live here: callers still send their own
// `Authorization: Bearer <key>` and it is forwarded untouched.
//
// Deploy: Cloudflare dashboard → Workers & Pages → Create Worker → paste
// this file → Deploy. Or `wrangler deploy` with this file as main.

const ORIGIN = "https://sando-pulse.onrender.com";

// Short edge-cache TTLs (seconds) for safe GET endpoints only.
// /v1/health changes as documents are ingested, so it stays short.
const CACHE_TTLS = {
  "/v1/health": 60,
  "/v1/sources": 300,
};

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const target = new URL(url.pathname + url.search, ORIGIN);

    const init = {
      method: request.method,
      headers: request.headers,
      body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
      redirect: "manual",
    };

    // Edge-cache safe GETs; POSTs and everything else go live to origin.
    const ttl = CACHE_TTLS[url.pathname];
    if (ttl !== undefined && request.method === "GET") {
      init.cf = { cacheTtl: ttl, cacheEverything: true };
    }

    const res = await fetch(target.toString(), init);
    const out = new Response(res.body, res);
    out.headers.set("x-pulse-edge", "cloudflare-worker");
    return out;
  },
};
