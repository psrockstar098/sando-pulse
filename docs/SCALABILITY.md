# Pulse scalability (Roadmap 5.5)

Architecture preparation for growth — interfaces, abstractions and
documented extension points. **Nothing here is a live multi-region
deployment.** Pulse today is one API process + one worker + one
Postgres + one Redis on one host. This document records what to change,
in what order, when each limit is actually hit.

## Where the limits are today

| Resource | Today | First limit hit |
| -------- | ----- | --------------- |
| API | 1 process, single-threaded request loop (+ 2nd instance + nginx LB via the `scale` profile, Roadmap 6.9) | CPU on concurrent queries |
| Worker | 1 process (+ optional 2nd via the `scale` profile) | Ingest throughput |
| Postgres | 1 primary, pool size 1 by default | Concurrent search reads |
| Redis | 1 instance, 256 MB maxmemory, allkeys-lru | Cache + stream volume |
| Search | Sequential scan over documents (no vector index) | ~10k+ documents |
| Object storage | MinIO (or none) on the same host | Raw archive volume |

## Statelessness contract (Roadmap 6.9)

The API is stateless **except for four per-instance caches**, each
safe to lose. Any instance can serve any request; nothing a client
does depends on landing on the same instance twice.

| State | Where | Lost when | Consequence |
| ----- | ----- | --------- | ----------- |
| L1 in-process cache (6.2) | Per API instance | Instance restarts / new instance | Cold L1: the first asks miss and compute fresh; the shared Redis L2 still serves them. Bounded by `PULSE_L1_MAX_ENTRIES` / `PULSE_L1_MAX_BYTES`. |
| In-memory index (6.3/6.5) | Per API instance | Instance restarts / new instance | Rebuilt from the store at boot (`memindex built` log line; 0 ms at 3 docs — re-measure at real scale) and on Redis epoch changes. Until the build finishes, queries fall back to the store search. |
| Popular list (6.4) | Per API instance, local `popular.json` | Instance restarts without the file / new instance | A new instance starts with an empty tracker and no warming until it has seen queries. The file is NOT shared between instances — if warming matters on a scaled-out deploy, put `PULSE_POPULAR_PATH` on a shared volume. |
| Auto-tuner values (6.10) | Per API instance | Instance restarts | Each instance tunes its own knobs from its own traffic; reset is per instance (`POST /v1/admin/autotune/reset`) or a restart. There is no shared tuning state. |

Shared state (the contract — every instance reads/writes the same):
Postgres (documents, knowledge, audit, usage counters), Redis (L2
query cache, cache epochs, Streams event bus, usage counters),
MinIO (raw feed archives). A request's auth, rate limit, quota,
and audit trail are all enforced against this shared state, so
scaling the API out changes none of the guarantees.

### API scale-out shape (Roadmap 6.9)

`docker compose --profile scale up -d` starts a second API
instance (`api-2`, no published port) plus an nginx load balancer
(`lb`, host port 9080) in front of `api:9000` + `api-2:9000`
(round-robin, see `docker/nginx.conf`). Point clients at the LB;
in production give the LB port 9000 and drop the api services'
host port mappings. The shape is authored, not run: this VM cannot
run the compose stack (podman `--network none`), so the first real
`docker compose --profile scale up` on a Docker host is the
validation step. Honest limit: open-source nginx has no active
health checks — a dead backend is skipped only after a failed
request, not proactively.

### Workers — N workers (Roadmap 6.9)

The `scale` profile already ships `worker-2` (distinct
`PULSE_WORKER_ID`, separate Redis Streams consumer). A third worker
is the same block copied with `PULSE_WORKER_ID: "worker-3"` — no
code change; the stream group splits the realtime work and the
ingest loop is idempotent (re-runs are safe). See "Workers —
horizontal scaling" below.

### When to cluster / partition (triggers, not builds)

Redis clustering and Postgres partitioning are **documented
triggers, not built**: do not build them until measured demand
justifies it.

- **Redis cluster:** when the single instance's 256 MB maxmemory
  is the binding constraint — watch the eviction rate and the L2
  hit rate in `/metrics`: sustained evictions with a falling L2
  hit ratio while the working set keeps growing means the cache no
  longer fits one node. First step is raising `maxmemory` on a
  bigger host, not clustering; cluster only when one host's memory
  cannot hold the working set.
- **Postgres partitioning:** when one primary cannot keep up —
  sustained fast-path p95 above target with the database as the
  measured bottleneck (slow-query log / `pg_stat_statements`),
  or connection-pool saturation under load. First steps are the
  read replica (`PULSE_DATABASE_REPLICA_URL`, already built) and
  the prepared-statement work (6.8); partition by time (monthly
  `documents` partitions) only when those are exhausted.
- **Multi-region:** `PULSE_COUNTRY` already scopes the deployment
  to one country; a second region is a second full stack (API +
  worker + Postgres + Redis) with Postgres logical replication
  between them. Not built; the statelessness contract above is
  what makes it possible at all.

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
