-- 014_monitor_last_new.sql — Trust & Intelligence Engine, Phase 2
-- (2026-11-14). Live account monitoring.
--
-- `source_health.last_new_at` records the last time a source
-- produced a NEW document (an insert, not just a successful fetch).
-- The monitor (GET /v1/monitor) reads it to answer "when did this
-- source last publish something new" — a fetch that returns nothing
-- new is not activity. NULL until a run first inserts a document
-- for the source; never backfilled, never guessed.

ALTER TABLE source_health ADD COLUMN IF NOT EXISTS last_new_at TIMESTAMPTZ;
