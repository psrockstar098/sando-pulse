-- Roadmap 3.4 knowledge database + 3.1 source health + 3.3 lang/summary.
-- Events are persisted clusters (incremental find-or-create at ingest);
-- entities/topics are counted per document; locations/facilities/
-- statistics are seeded reference data (Roadmap 3.6) plus OSM results.
-- source_health records per-source fetch outcomes for 3.1 monitoring.
-- monthly_aggregates holds historical rollups for 3.5.
--
-- NOTE: migration 001 already created `events`, `event_sources`,
-- `entities`, `topics` and `locations` with different shapes, so the
-- CREATE TABLE IF NOT EXISTS statements below SKIP those tables on any
-- database that ran 001. See migration 005_reconcile_knowledge.sql,
-- which ALTERs the 001 tables to the shapes the knowledge store uses.
-- `facilities`, `statistics`, `source_health`, `monthly_aggregates`
-- are new here and are created by this file.

CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  topic TEXT NOT NULL DEFAULT '',
  first_seen TIMESTAMPTZ NOT NULL,
  last_seen TIMESTAMPTZ NOT NULL,
  doc_count INT NOT NULL DEFAULT 1,
  summary TEXT
);

CREATE TABLE IF NOT EXISTS event_sources (
  event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  doc_count INT NOT NULL DEFAULT 1,
  PRIMARY KEY (event_id, source_id)
);

CREATE TABLE IF NOT EXISTS entities (
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  first_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
  doc_count INT NOT NULL DEFAULT 1,
  PRIMARY KEY (name, kind)
);

CREATE TABLE IF NOT EXISTS topics (
  name TEXT PRIMARY KEY,
  doc_count INT NOT NULL DEFAULT 1,
  first_seen TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS locations (
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  county TEXT,
  lat DOUBLE PRECISION,
  lon DOUBLE PRECISION,
  source TEXT NOT NULL DEFAULT '',
  verified_at DATE,
  PRIMARY KEY (name, kind)
);

CREATE TABLE IF NOT EXISTS facilities (
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  county TEXT,
  city TEXT,
  lat DOUBLE PRECISION,
  lon DOUBLE PRECISION,
  source TEXT NOT NULL DEFAULT '',
  verified_at DATE,
  PRIMARY KEY (name, kind, county)
);

CREATE TABLE IF NOT EXISTS statistics (
  key TEXT PRIMARY KEY,
  value DOUBLE PRECISION NOT NULL,
  unit TEXT NOT NULL DEFAULT '',
  period TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  verified_at DATE
);

CREATE TABLE IF NOT EXISTS source_health (
  source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
  last_run_at TIMESTAMPTZ,
  last_success_at TIMESTAMPTZ,
  last_error TEXT,
  consecutive_failures INT NOT NULL DEFAULT 0,
  docs_total INT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS monthly_aggregates (
  year_month TEXT NOT NULL,
  topic TEXT NOT NULL,
  doc_count INT NOT NULL DEFAULT 0,
  PRIMARY KEY (year_month, topic)
);

-- Roadmap 3.3: language + stored summary on documents.
ALTER TABLE documents ADD COLUMN IF NOT EXISTS lang TEXT NOT NULL DEFAULT 'en';
ALTER TABLE documents ADD COLUMN IF NOT EXISTS summary TEXT;
