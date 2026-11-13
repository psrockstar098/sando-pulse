-- 011_audit_log.sql — append-only API audit records (Roadmap 5.3).
-- One row per authenticated /v1/query, /v1/ingest and /v1/usage call,
-- including denials. key_fp is the first 8 hex chars of SHA-256 of the
-- presented API key — the key itself is never stored.
CREATE TABLE IF NOT EXISTS audit_log (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT now(),
  consumer TEXT NOT NULL,
  key_fp TEXT NOT NULL,
  route TEXT NOT NULL,
  method TEXT NOT NULL,
  status INT NOT NULL,
  request_id TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS audit_log_ts_idx ON audit_log (ts DESC);
CREATE INDEX IF NOT EXISTS audit_log_consumer_idx ON audit_log (consumer, ts DESC);
