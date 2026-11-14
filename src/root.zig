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
pub const engine_geo = @import("engine/geo.zig");
pub const engine_intent = @import("engine/intent.zig");
pub const engine_language = @import("engine/language.zig");
pub const engine_memindex = @import("engine/memindex.zig");
pub const engine_router = @import("engine/router.zig");
pub const engine_fanout = @import("engine/fanout.zig");
pub const engine_autotune = @import("engine/autotune.zig");
pub const engine_breaker = @import("engine/breaker.zig");
pub const engine_planner = @import("engine/planner.zig");
pub const engine_ranking = @import("engine/ranking.zig");
pub const engine_search = @import("engine/search.zig");
pub const engine_temporal = @import("engine/temporal.zig");
pub const engine_vectors = @import("engine/vectors.zig");
pub const ingestion_connectors = @import("ingestion/connectors.zig");
pub const ingestion_facebook = @import("ingestion/connectors/facebook/facebook.zig");
pub const ingestion_facebook_auth = @import("ingestion/connectors/facebook/auth.zig");
pub const ingestion_facebook_client = @import("ingestion/connectors/facebook/client.zig");
pub const ingestion_facebook_normalizer = @import("ingestion/connectors/facebook/normalizer.zig");
pub const ingestion_facebook_notifications = @import("ingestion/connectors/facebook/notifications.zig");
pub const ingestion_facebook_pages = @import("ingestion/connectors/facebook/pages.zig");
pub const ingestion_facebook_pagination = @import("ingestion/connectors/facebook/pagination.zig");
pub const ingestion_facebook_posts = @import("ingestion/connectors/facebook/posts.zig");
pub const ingestion_facebook_scheduler = @import("ingestion/connectors/facebook/scheduler.zig");
pub const ingestion_facebook_types = @import("ingestion/connectors/facebook/types.zig");
pub const ingestion_facebook_webhooks = @import("ingestion/connectors/facebook/webhooks.zig");
pub const ingestion_fetchers = @import("ingestion/fetchers.zig");
pub const ingestion_ssrf = @import("ingestion/ssrf.zig");
pub const ingestion_normalizer = @import("ingestion/normalizer.zig");
pub const ingestion_pipeline = @import("ingestion/pipeline.zig");
pub const ingestion_rss = @import("ingestion/rss.zig");
pub const ingestion_sources = @import("ingestion/sources.zig");
pub const ingestion_source_manager = @import("ingestion/source_manager.zig");
pub const ingestion_validate = @import("ingestion/validate.zig");
pub const storage_memory = @import("storage/memory.zig");
pub const storage_knowledge = @import("storage/knowledge.zig");
pub const storage_object_store = @import("storage/object_store.zig");
pub const storage_compression = @import("storage/compression.zig");
pub const storage_maintenance = @import("storage/maintenance.zig");
// TODO(integration): re-enable once the Postgres client lands.
pub const storage_postgres = @import("storage/postgres.zig");
pub const storage_postgres_knowledge = @import("storage/postgres_knowledge.zig");
pub const storage_redis = @import("storage/redis.zig");
pub const storage_repository = @import("storage/repository.zig");
pub const workers_worker = @import("workers/worker.zig");
pub const workers_realtime = @import("workers/realtime.zig");
pub const api_cache = @import("api/cache.zig");
pub const api_l1cache = @import("api/l1cache.zig");
pub const api_popular = @import("api/popular.zig");
pub const api_usage = @import("api/usage.zig");
pub const api_auditlog = @import("api/auditlog.zig");
pub const sando_client = @import("sando/client.zig");
pub const cli_mock_sando = @import("cli/mock_sando.zig");
pub const ai_providers = @import("ai/providers.zig");
pub const seed_liberia = @import("seed/liberia.zig");
pub const intelligence_events = @import("intelligence/events.zig");
pub const intelligence_trending = @import("intelligence/trending.zig");
pub const intelligence_forecast = @import("intelligence/forecast.zig");
pub const intelligence_statanswer = @import("intelligence/statanswer.zig");
pub const intelligence_alerts = @import("intelligence/alerts.zig");
pub const intelligence_precomputed = @import("intelligence/precomputed.zig");
pub const intelligence_social = @import("intelligence/social.zig");
pub const intelligence_quality = @import("intelligence/quality.zig");
pub const intelligence_trust_registry = @import("intelligence/trust/source_registry.zig");
pub const intelligence_trust_history = @import("intelligence/trust/source_history.zig");
pub const intelligence_trust_evidence = @import("intelligence/trust/evidence_tracker.zig");
pub const intelligence_trust_corroboration = @import("intelligence/trust/corroboration.zig");
pub const intelligence_trust_score = @import("intelligence/trust/credibility_score.zig");
pub const intelligence_monitor = @import("intelligence/monitor/account_monitor.zig");
pub const cli_loadtest = @import("cli/loadtest.zig");
pub const cli_audit = @import("cli/audit.zig");
pub const cli_backup = @import("cli/backup.zig");

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
