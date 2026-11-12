-- 002_search_indexes.sql — full-text search + lookup indexes (Roadmap 1).
-- Applied after 001_initial.sql by `pulse migrate`.

-- Full-text search vector over title + text (PostgreSQL FTS).
ALTER TABLE documents
    ADD COLUMN IF NOT EXISTS search_vector tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(title, '') || ' ' || coalesce(text, ''))
    ) STORED;

CREATE INDEX IF NOT EXISTS documents_search_idx
    ON documents USING GIN (search_vector);

CREATE INDEX IF NOT EXISTS documents_source_idx
    ON documents (source_id, published_at DESC);

CREATE INDEX IF NOT EXISTS documents_published_idx
    ON documents (published_at DESC);

CREATE INDEX IF NOT EXISTS documents_fetched_idx
    ON documents (fetched_at DESC);

CREATE INDEX IF NOT EXISTS events_status_idx
    ON events (status, last_seen_at DESC);

CREATE INDEX IF NOT EXISTS audit_logs_ts_idx
    ON audit_logs (ts DESC);
