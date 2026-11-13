-- 010_performance_indexes.sql — Roadmap 4.5: search/index optimization.
--
-- Migration 001 created the knowledge tables with primary keys only;
-- no indexes existed on events at all except the status index, so
-- "latest events" and "latest events in a topic" (the briefing and
-- /v1/events paths) were sequential scans. The composite documents
-- index serves the "latest N from source X" pattern used by
-- per-source scans. Column names are the real ones from 001:
-- events.last_seen_at (not last_seen — 004's CREATE TABLE never ran
-- because 001 already created the table).
-- All indexes are created IF NOT EXISTS so the migration is safe to
-- re-run on a store that already has them.

CREATE INDEX IF NOT EXISTS events_last_seen_at_idx
    ON events (last_seen_at DESC);

CREATE INDEX IF NOT EXISTS events_topic_last_seen_at_idx
    ON events (topic, last_seen_at DESC);

CREATE INDEX IF NOT EXISTS documents_source_fetched_idx
    ON documents (source_id, fetched_at DESC);
