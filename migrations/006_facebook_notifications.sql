-- 006: Facebook webhook notifications (Roadmap 3.2).
-- The server process records validated webhook notifications here;
-- the worker process drains them and polls the notified pages.
-- id is the deterministic SHA-256 hex of
-- page_id + received_at + kind + object_id (computed in Zig), so a
-- retried webhook delivery inserts once (ON CONFLICT DO NOTHING).
CREATE TABLE IF NOT EXISTS facebook_notifications (
    id TEXT PRIMARY KEY,
    page_id TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'feed',
    object_id TEXT NOT NULL DEFAULT '',
    -- Meta's entry time (seconds): part of the dedupe id; the same
    -- across retried deliveries of one notification.
    source_time BIGINT NOT NULL DEFAULT 0,
    received_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_facebook_notifications_pending
    ON facebook_notifications (received_at) WHERE processed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_facebook_notifications_page
    ON facebook_notifications (page_id, received_at);
