# Pulse module interfaces (Roadmap 1)

Single source of truth for cross-module contracts. Every implementation below
uses ONLY the Zig 0.17.1 standard library — no external packages.

## Repository (`src/storage/repository.zig`)

```zig
pub const Repository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        insertDocument: *const fn (ptr: *anyopaque, doc: types.Document) anyerror!void,
        search: *const fn (ptr: *anyopaque, alloc: Allocator, q: types.SearchQuery) anyerror![]types.Document,
        countDocuments: *const fn (ptr: *anyopaque) usize,
        countBySource: *const fn (ptr: *anyopaque, alloc: Allocator) anyerror![]types.SourceCount,
        scanDocuments: *const fn (ptr: *anyopaque, alloc: Allocator, before_ts: ?i64, limit: usize) anyerror![]types.Document,
        deleteDocuments: *const fn (ptr: *anyopaque, ids: []const []const u8) anyerror!usize,
        deinit: *const fn (ptr: *anyopaque) void,
    };
    // wrappers: insertDocument / search / countDocuments / countBySource /
    // scanDocuments / deleteDocuments / deinit
};
```

Rules:
- `search` returns documents with ALL strings owned by the caller's `alloc`
  (the caller passes a per-request arena). The engine ranks them afterwards.
- `search` is a COARSE candidate retrieval: return up to 100 documents
  matching any of `q.terms` (lexical/FTS) and honoring `q.counties`,
  `q.organizations`, `q.topics` filters when non-empty. The engine does the
  final ranking; the store must not invent scores.
- `insertDocument` is idempotent on `doc.id` (content hash): re-inserting the
  same document is a no-op, never an error, never a duplicate.
- `countBySource` returns one entry per source that has >= 1 document.

## Document (`src/common/types.zig`)

Fields: id, source_id, source_name, source_url, title, url, text,
published_at (?i64 unix), fetched_at (i64 unix), reliability (f32 0..1),
topics ([]const []const u8), content_hash. `contentHash(alloc, source_id, url,
title)` = hex SHA-256 over `source_id + "\n" + url + "\n" + title`.

## PostgreSQL client (`src/storage/postgres.zig`)

Must expose:

```zig
pub const PgClient = struct {
    pub fn connect(alloc: Allocator, io: std.Io, conninfo: []const u8) !PgClient;
    pub fn close(self: *PgClient) void;
    pub fn ping(self: *PgClient) !void;                       // SELECT 1
    pub fn exec(self: *PgClient, alloc: Allocator, sql: []const u8) !void; // simple-query, no rows expected
    pub fn query(self: *PgClient, alloc: Allocator, sql: []const u8) !QueryResult;
    // QueryResult: rows: []Row; Row: cols: []?[]const u8 (NULL-aware text values)
    // Row values are owned by the passed allocator (arena).
};
pub fn parseConnInfo(alloc: Allocator, s: []const u8) !ConnInfo; // postgres://user:pass@host:port/db
pub fn runMigrations(alloc: Allocator, io: std.Io, conninfo: []const u8, dir: []const u8) !void;
pub const PostgresStore = struct {
    pub fn init(alloc: Allocator, io: std.Io, conninfo: []const u8) !PostgresStore;
    pub fn repository(self: *PostgresStore) Repository;
    pub fn deinit(self: *PostgresStore) void;
};
```

Protocol requirements (real PostgreSQL wire protocol, std lib only):
- TCP via `std.Io.net`, startup message, auth: cleartext, MD5, and
  SCRAM-SHA-256 (use `std.crypto` HMAC-SHA256/SHA256; PostgreSQL 14+ defaults
  to SCRAM, so this is required, not optional).
- Simple Query protocol; parse RowDescription/DataRow/CommandComplete/ErrorResponse.
- `runMigrations`: read `<dir>/*.sql` sorted by name; for each file not yet in
  `schema_migrations`, run it inside `BEGIN; ... COMMIT;` then
  `INSERT INTO schema_migrations(version)`. Idempotent re-runs.
- `PostgresStore.search`: `plainto_tsquery`/`websearch_to_tsquery` over
  `search_vector` OR `ILIKE` fallback per term, `LIMIT 100`. Never build SQL
  by concatenating user input: use `escapeLiteral` (single-quote doubling)
  and validate identifiers. Terms come from the planner, not raw users, but
  escape anyway.
- Connection pool: a small fixed pool (4 connections) behind a mutex is
  enough for Phase 1; document it if you simplify to one connection + mutex.
- Tests in the same file: message-encoding unit tests (startup, MD5,
  SCRAM client-first message), `escapeLiteral`, `parseConnInfo`, plus a live
  test that runs ONLY when `PULSE_TEST_POSTGRES_URL` is set (otherwise it
  prints `skip: PULSE_TEST_POSTGRES_URL not set` and passes): connect, run
  migrations from `migrations/`, insert a doc, search it back, count it.

## Redis client (`src/storage/redis.zig`)

Must expose:

```zig
pub const RespValue = union(enum) { simple: []const u8, err: []const u8, integer: i64, bulk: ?[]const u8, array: ?[]RespValue };
pub const RedisClient = struct {
    pub fn connect(alloc: Allocator, io: std.Io, url: []const u8) !RedisClient; // redis://host:port
    pub fn close(self: *RedisClient) void;
    pub fn ping(self: *RedisClient) !void;
    pub fn command(self: *RedisClient, alloc: Allocator, args: []const []const u8) !RespValue;
    pub fn get(self: *RedisClient, alloc: Allocator, key: []const u8) !?[]u8;
    pub fn setex(self: *RedisClient, key: []const u8, seconds: u64, value: []const u8) !void;
    pub fn xadd(self: *RedisClient, alloc: Allocator, stream: []const u8, fields: []const Field) ![]u8; // returns entry id
    pub fn xgroupCreate(self: *RedisClient, stream: []const u8, group: []const u8) !void; // MKSTREAM, ignore BUSYGROUP
    pub fn xreadgroup(self: *RedisClient, alloc: Allocator, group: []const u8, consumer: []const u8, stream: []const u8, count: usize, block_ms: u64) ![]StreamEntry;
    pub fn xrange(self: *RedisClient, alloc: Allocator, stream: []const u8, count: usize) ![]StreamEntry;
};
pub const Field = struct { name: []const u8, value: []const u8 };
pub const StreamEntry = struct { id: []const u8, fields: []Field };
pub const EventBus = struct {
    pub fn init(client: *RedisClient) EventBus;
    pub fn publishDocumentCollected(self: *EventBus, alloc: Allocator, doc_id: []const u8, source_id: []const u8) ![]u8;
};
```

- RESP2 encode/decode, std lib only, TCP via `std.Io.net`.
- Stream name: `pulse:events`. Event fields: `type=document.collected`,
  `document_id`, `source_id`, `ts` (unix millis).
- Tests in the same file: RESP encode/decode unit tests (all 5 types,
  nested arrays, nil bulk/array), plus a live test that runs ONLY when
  `PULSE_TEST_REDIS_URL` is set (otherwise skip-print and pass): PING, SETEX/
  GET round-trip, XADD + XRANGE round-trip, XGROUP CREATE + XREADGROUP.

## Shared rules for both clients

- Both take `io: std.Io` as a parameter (the caller owns the `Threaded` Io).
- Timeouts: use `std.Io.net` stream timeouts where the API allows; otherwise
  document that the caller must bound the call. Never block forever on a dead
  peer in a way the server cannot survive — log and return an error.
- No secrets in logs. No `std.debug.print` of connection strings (they carry
  passwords); log `host:port/db` only.
- Do NOT edit `build.zig`, migrations, or any file outside your owned file.
  Do NOT commit. Report the exact test counts from `zig test <your file>`.
