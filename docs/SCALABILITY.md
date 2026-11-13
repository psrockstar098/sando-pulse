# Pulse scalability (Roadmap 5.5)

Architecture preparation for growth — interfaces, abstractions and
documented extension points. **Nothing here is a live multi-region
deployment.** Pulse today is one API process + one worker + one
Postgres + one Redis on one host. This document records what to change,
in what order, when each limit is actually hit.

## Where the limits are today

| Resource | Today | First limit hit |
| -------- | ----- | --------------- |
| API | 1 process, single-threaded request loop | CPU on concurrent queries |
| Worker | 1 process (+ optional 2nd via the `scale` profile) | Ingest throughput |
| Postgres | 1 primary, pool size 1 by default | Concurrent search reads |
| Redis | 1 instance, 256 MB maxmemory, allkeys-lru | Cache + stream volume |
| Search | Sequential scan over documents (no vector index) | ~10k+ documents |
| Object storage | MinIO (or none) on the same host | Raw archive volume |

## Extension points (already built)

### Repository interface — new datasets, new backends

`src/storage/repository.zig` is the ONE storage contract: every engine,
API and worker call goes through its vtable (`insertDocument`,
`search`, `countDocuments`, `countBySource`, `scanDocuments`,
`deleteDocuments`). The in-memory store and the Postgres store both
implement it. To add a dataset or a backend:

1. Implement the vtable for the new store.
2. Select it in `src/main.zig` where the store is constructed.
3. Nothing else changes — the query engine, the API and the worker
   never know which backend is behind the interface.

A dataset is a new `source_id` in the registry plus, if its shape
differs, a new document kind in `src/common/types.zig`. The search
engine ranks by topic/reliability/recency regardless of dataset.

### Connectors — new sources

`src/ingestion/connectors/` is the connector interface
(`collect`/`validate`, one module per source family). The Facebook
connector (`connectors/facebook/`) is the worked example: Graph API
primary, webhooks with HMAC validation, polling fallback, registry as
config not code. A new connector (YouTube, Reddit, Google News, a
government open-data portal) is a new module under that directory plus
a registry entry — no engine changes. The rules that bind every
connector: authorized access only, no scraping, no invented
credentials, SSRF-checked fetches.

### Consumers — multiple callers

Consumers are config, not code: `PULSE_CONSUMERS` registers a name,
its scopes (`query`/`ingest`/`admin`) and its daily quota. Usage is
tracked per consumer in Redis (`pulse:usage:<consumer>:<day>:<kind>`)
and audited per call. Adding a caller is a config change and a restart
— no deploy. The `default` consumer exists only when no consumers are
configured.

### Countries — multi-country deployments

`PULSE_COUNTRY` (default `"lr"`, ISO 3166-1 alpha-2) is reported in
`/v1/health` and `pulse status`. Today it is a label only: one Pulse
instance serves one country. To serve a second country:

1. Run a second instance with `PULSE_COUNTRY=<other>` and its own
   database (locations, sources and statistics are seeded per country
   — `src/seed/liberia.zig` is the pattern to copy for a new country
   seed module).
2. Put a router in front that sends a request to the instance matching
   the requested country (header or path prefix).
3. Do NOT merge countries into one database until a `country` column
   exists on documents, locations and statistics and every query
   filters on it — that migration is the real multi-tenant step, and it
   is deliberately not done yet.

### Workers — horizontal scaling

Workers are stateless apart from Postgres/Redis: the ingest loop reads
sources and writes documents; realtime work goes through Redis
Streams consumer groups, where each worker is named by
`PULSE_WORKER_ID`. Scaling is `docker compose --profile scale up -d`
for a second worker, or more `worker-N` services for more. No code
change is needed to add workers; the stream group splits the work.

### Read replicas — search reads

`PULSE_DATABASE_REPLICA_URL` attaches a second Postgres pool
(`PostgresStore.setReplica`, 2 connections). When set, the read
methods — `search`, `countDocuments`, `countBySource`,
`scanDocuments` — check out from the replica pool; writes
(`insertDocument`, `deleteDocuments`) always stay on the primary.
If the replica checkout fails, reads fall back to the primary, so a
dead replica never takes reads down. A replica that fails to connect
at boot is logged and ignored. Reads from a replica may lag the
primary by the replication delay — acceptable for search and counts,
which is why the routing is read-only by construction. Tested live in
`src/storage/postgres.zig` ("read replica routes reads, falls back on
failure").

When one replica is not enough: add more replica URLs the same way
(one pool per replica, round-robin in `checkoutRead`) — the hook is
the same function.

### Dedicated search infrastructure

When the document count outgrows the sequential scan (the local
embedding is lexical, and there is no vector index yet):

1. Add a real vector index (`CREATE INDEX ... USING hnsw` on the
   `embedding` column) — the schema already stores `vector(128)`.
2. Or move search to a dedicated engine behind the same Repository
   vtable (e.g. a search service that implements `search` only and
   delegates the rest to Postgres). The vtable makes that a contained
   change: the API and engine do not care where `search` runs.
3. Swap the lexical embedder for a real embedding provider
   (`src/ai/providers.zig` already has the external-provider interface;
   it has never been called live — it needs an API key).

### Distributed object storage

Raw archives go through `src/storage/object_store.zig` (S3-compatible
client). Today it points at the local MinIO. Pointing it at a managed
S3 bucket is a config change (`MINIO_ENDPOINT` + credentials) — the
interface is already the S3 API, so no code changes.

### Multi-tenant controls

The building blocks exist and are deliberately separate:

- Consumers + scopes + quotas (5.3) = per-caller access control.
- Audit records (5.3) = per-caller accountability.
- Country label (5.5) = per-deployment scoping.

What does NOT exist yet, and must be designed before multi-tenancy is
claimed: per-tenant data isolation (a `tenant`/`country` column with
row-level filtering on every query), per-tenant rate limits beyond the
consumer quota, and tenant-scoped API keys. Do not sell multi-tenancy
until those three are built and tested.

## Scaling order (when to do what)

1. **Reads get slow** → set `PULSE_DATABASE_REPLICA_URL`; raise
   `PULSE_PG_POOL_SIZE` (default 1).
2. **Ingest lags** → add workers (`--profile scale`, then more
   `worker-N` services).
3. **Cache hit rate falls** → raise Redis `maxmemory` in
   `docker-compose.yml` (256 MB today).
4. **Search gets slow** → HNSW index on `embedding`, then a dedicated
   search service behind the Repository vtable.
5. **One host is not enough** → second country instance + router (see
   Countries above); object storage to managed S3.
6. **True multi-tenancy** → country/tenant column + row filtering +
   per-tenant keys. Design first; this is the only step on this list
   that changes the data model.
