-- 005_reconcile_knowledge.sql — Roadmap 3.4 reconciliation.
--
-- Migration 001 (Roadmap 1) already created `events`, `event_sources`,
-- `entities`, `topics` and `locations` with DIFFERENT shapes than the
-- ones migration 004 assumed, so 004's CREATE TABLE IF NOT EXISTS
-- statements skipped them silently. This migration ALTERs the 001 tables
-- forward to the shapes the knowledge store needs; it never drops or
-- redefines a table, and the 001 seed data (15 counties, 12 topics,
-- 10 sources) is preserved and merged with, never replaced.
--
-- Reconciled shapes:
--   entities:      001 (id, kind, name, UNIQUE(kind, name))
--                  + first_seen, doc_count. id is deterministic
--                  "<kind>:<slug>" (e.g. "city:monrovia").
--   events:        001 (id, title, category, status, first_seen_at,
--                  last_seen_at, source_count, verification_status,
--                  trend_score) + topic, doc_count, summary.
--                  `category` mirrors `topic`; `source_count` is the
--                  distinct-source count over linked documents.
--   event_sources: 001 (event_id, document_id) — links events to
--                  DOCUMENTS (evidence), not to sources. The knowledge
--                  store inserts one row per document; doc_count on the
--                  event is the authoritative per-event document count.
--   topics:        001 (id, name) + doc_count, first_seen. id = name,
--                  matching the 001 seed rows ('energy', 'energy').
--   locations:     001 (id, name, kind, parent_id, population,
--                  latitude, longitude) + county, source, verified_at
--                  and UNIQUE(name, kind) so upserts merge with the
--                  001 county seed instead of duplicating it.
--                  Latitude/longitude are the 001 columns; no separate
--                  lat/lon columns are added.

-- entities: counts + first sighting.
ALTER TABLE entities
  ADD COLUMN IF NOT EXISTS first_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS doc_count INT NOT NULL DEFAULT 1;

-- events: topic, document count, stored summary.
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS topic TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS doc_count INT NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS summary TEXT;

-- topics: counts + first sighting.
ALTER TABLE topics
  ADD COLUMN IF NOT EXISTS doc_count INT NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS first_seen TIMESTAMPTZ NOT NULL DEFAULT now();

-- locations: county label, provenance, and a merge key.
ALTER TABLE locations
  ADD COLUMN IF NOT EXISTS county TEXT,
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS verified_at DATE;
-- The 001 county seed has 15 distinct names, so this is safe.
CREATE UNIQUE INDEX IF NOT EXISTS locations_name_kind_key
  ON locations (name, kind);
