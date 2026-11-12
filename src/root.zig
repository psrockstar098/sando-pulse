//! Library root: re-exports every Pulse module so `zig test src/root.zig`
//! (and `zig build test`) compiles and runs the whole test suite in one
//! module. Cross-directory relative imports work only inside this tree —
//! never run `zig test` on an individual file that imports outside its own
//! directory.

pub const common_types = @import("common/types.zig");
pub const common_errors = @import("common/errors.zig");
pub const common_format = @import("common/format.zig");
pub const common_logging = @import("common/logging.zig");
pub const common_time = @import("common/time.zig");
pub const config = @import("config/config.zig");
pub const api_auth = @import("api/auth.zig");
pub const api_metrics = @import("api/metrics.zig");
pub const api_query = @import("api/query.zig");
pub const api_ratelimit = @import("api/ratelimit.zig");
pub const api_server = @import("api/server.zig");
pub const engine_entities = @import("engine/entities.zig");
pub const engine_fuzzy = @import("engine/fuzzy.zig");
pub const engine_intent = @import("engine/intent.zig");
pub const engine_planner = @import("engine/planner.zig");
pub const engine_ranking = @import("engine/ranking.zig");
pub const engine_search = @import("engine/search.zig");
pub const engine_temporal = @import("engine/temporal.zig");
pub const engine_vectors = @import("engine/vectors.zig");
pub const ingestion_fetchers = @import("ingestion/fetchers.zig");
pub const ingestion_normalizer = @import("ingestion/normalizer.zig");
pub const ingestion_pipeline = @import("ingestion/pipeline.zig");
pub const ingestion_rss = @import("ingestion/rss.zig");
pub const ingestion_sources = @import("ingestion/sources.zig");
pub const storage_memory = @import("storage/memory.zig");
pub const storage_object_store = @import("storage/object_store.zig");
// TODO(integration): re-enable once the Postgres client lands.
pub const storage_postgres = @import("storage/postgres.zig");
pub const storage_redis = @import("storage/redis.zig");
pub const storage_repository = @import("storage/repository.zig");
pub const workers_worker = @import("workers/worker.zig");

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
