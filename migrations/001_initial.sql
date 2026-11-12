-- 001_initial.sql — Pulse core schema (Roadmap 1).
-- Applied in order by `pulse migrate` (see src/storage/postgres.zig).
-- Every migration runs inside its own transaction and is recorded in
-- schema_migrations, so re-running is a no-op.

CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sources (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    home_url TEXT NOT NULL,
    feed_url TEXT NOT NULL,
    reliability REAL NOT NULL DEFAULT 0.70,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    disabled_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL REFERENCES sources(id),
    title TEXT NOT NULL,
    url TEXT NOT NULL UNIQUE,
    text TEXT NOT NULL DEFAULT '',
    published_at TIMESTAMPTZ,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reliability REAL NOT NULL DEFAULT 0.70,
    topics TEXT[] NOT NULL DEFAULT '{}',
    content_hash TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'general',
    status TEXT NOT NULL DEFAULT 'reported',
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_count INTEGER NOT NULL DEFAULT 0,
    verification_status TEXT NOT NULL DEFAULT 'unverified',
    trend_score REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS event_sources (
    event_id TEXT NOT NULL REFERENCES events(id),
    document_id TEXT NOT NULL REFERENCES documents(id),
    PRIMARY KEY (event_id, document_id)
);

CREATE TABLE IF NOT EXISTS entities (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    UNIQUE (kind, name)
);

CREATE TABLE IF NOT EXISTS event_entities (
    event_id TEXT NOT NULL REFERENCES events(id),
    entity_id TEXT NOT NULL REFERENCES entities(id),
    PRIMARY KEY (event_id, entity_id)
);

CREATE TABLE IF NOT EXISTS locations (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    parent_id TEXT REFERENCES locations(id),
    population BIGINT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS topics (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS document_topics (
    document_id TEXT NOT NULL REFERENCES documents(id),
    topic_id TEXT NOT NULL REFERENCES topics(id),
    PRIMARY KEY (document_id, topic_id)
);

CREATE TABLE IF NOT EXISTS trend_snapshots (
    topic_id TEXT NOT NULL REFERENCES topics(id),
    period_start TIMESTAMPTZ NOT NULL,
    mentions INTEGER NOT NULL DEFAULT 0,
    unique_sources INTEGER NOT NULL DEFAULT 0,
    trend_score REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (topic_id, period_start)
);

-- API keys are stored ONLY as hashes. Raw keys are never persisted.
CREATE TABLE IF NOT EXISTS api_keys (
    id TEXT PRIMARY KEY,
    key_hash TEXT NOT NULL UNIQUE,
    consumer_id TEXT NOT NULL DEFAULT 'sando',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ,
    revoked BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS audit_logs (
    id BIGSERIAL PRIMARY KEY,
    ts TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor TEXT NOT NULL,
    action TEXT NOT NULL,
    detail TEXT NOT NULL DEFAULT ''
);

-- Seed: the 15 counties of Liberia (location hierarchy level 2).
INSERT INTO locations (id, name, kind) VALUES
    ('loc_bomi', 'Bomi', 'county'),
    ('loc_bong', 'Bong', 'county'),
    ('loc_gbarpolu', 'Gbarpolu', 'county'),
    ('loc_grand_bassa', 'Grand Bassa', 'county'),
    ('loc_grand_cape_mount', 'Grand Cape Mount', 'county'),
    ('loc_grand_gedeh', 'Grand Gedeh', 'county'),
    ('loc_grand_kru', 'Grand Kru', 'county'),
    ('loc_lofa', 'Lofa', 'county'),
    ('loc_margibi', 'Margibi', 'county'),
    ('loc_maryland', 'Maryland', 'county'),
    ('loc_montserrado', 'Montserrado', 'county'),
    ('loc_nimba', 'Nimba', 'county'),
    ('loc_river_cess', 'River Cess', 'county'),
    ('loc_river_gee', 'River Gee', 'county'),
    ('loc_sinoe', 'Sinoe', 'county')
ON CONFLICT (id) DO NOTHING;

-- Seed: the first 10 sources (enabled flags match src/ingestion/sources.zig,
-- verified live 2026-11-12).
INSERT INTO sources (id, name, home_url, feed_url, reliability, enabled, disabled_reason) VALUES
    ('frontpage-africa', 'FrontPage Africa', 'https://frontpageafricaonline.com/', 'https://frontpageafricaonline.com/feed/', 0.70, FALSE, 'Cloudflare bot challenge blocks non-browser HTTP clients (verified 2026-11-12)'),
    ('daily-observer', 'Daily Observer', 'https://www.liberianobserver.com/', 'http://www.liberianobserver.com/search/?f=rss&t=article&l=50&s=start_time&sd=desc', 0.70, TRUE, NULL),
    ('new-dawn', 'New Dawn', 'https://thenewdawnliberia.com/', 'https://thenewdawnliberia.com/feed/', 0.70, TRUE, NULL),
    ('liberian-investigator', 'Liberian Investigator', 'https://liberianinvestigator.com/', 'https://liberianinvestigator.com/feed/', 0.70, TRUE, NULL),
    ('gnn-liberia', 'GNN Liberia', 'https://gnnliberia.com/', 'https://gnnliberia.com/feed/', 0.70, TRUE, NULL),
    ('kmtv', 'KMTV', 'https://kmtvliberia.com/', 'https://kmtvliberia.com/feed/', 0.70, FALSE, 'Homepage loads but no RSS feed or sitemap exists (verified 2026-11-12)'),
    ('spoon-tv', 'Spoon TV', 'https://www.spoonfmradio.com/', 'https://www.spoonfmradio.com/feed/', 0.70, FALSE, 'Feed URL returns a 114-byte lander redirect stub, no content (verified 2026-11-12)'),
    ('bush-chicken', 'Bush Chicken', 'https://bushchicken.com/', 'https://bushchicken.com/feed/', 0.70, FALSE, 'Feed URL returns a 114-byte lander redirect stub, no content (verified 2026-11-12)'),
    ('new-republic', 'New Republic', 'https://www.newrepublicliberia.com/', 'https://www.newrepublicliberia.com/feed/', 0.70, FALSE, 'Domain parked on Hostinger DNS; site does not exist (verified 2026-11-12)'),
    ('the-news', 'The News', 'https://thenewsnewspaperonline.com/', 'https://thenewsnewspaperonline.com/feed/', 0.70, TRUE, NULL)
ON CONFLICT (id) DO NOTHING;

-- Seed: the topic taxonomy from the design doc.
INSERT INTO topics (id, name) VALUES
    ('energy', 'energy'),
    ('economy', 'economy'),
    ('health', 'health'),
    ('politics', 'politics'),
    ('society', 'society'),
    ('culture', 'culture'),
    ('education', 'education'),
    ('sports', 'sports'),
    ('crime', 'crime'),
    ('business', 'business'),
    ('community', 'community'),
    ('entertainment', 'entertainment')
ON CONFLICT (id) DO NOTHING;
