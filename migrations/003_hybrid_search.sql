-- 003_hybrid_search.sql — Roadmap 2.2: hybrid search columns + extensions.
-- Applied after 002_search_indexes.sql by `pulse migrate`.
--
-- Extensions (all verified available on the local Postgres 16:
-- pg_available_extensions lists vector 0.6.0, postgis 3.4.2, pg_trgm 1.6).
-- No honest substitute was needed: pgvector and PostGIS install for real.
--
-- Columns:
--   embedding vector(128): document embedding from the configured provider.
--     The local provider (local-hash-lexical-v1) emits 128 dims by default;
--     PULSE_EMBEDDING_DIMS changes it, and the column must be recreated to
--     match (documented in STATUS.md). External providers must emit 128 dims
--     or set PULSE_EMBEDDING_DIMS + recreate the column.
--   lat / lon: WGS-84 coordinates when the document is linked to a known
--     Liberian place (set at ingest from the geo lookup; NULL otherwise).
--   geom: PostGIS geography point, set by the application alongside lat/lon.
--
-- Indexes:
--   Trigram GIN on title for fuzzy matching (pg_trgm).
--   GiST on geom for radius queries (ST_DWithin).
--   No vector index yet: ivfflat needs a trained corpus and HNSW adds
--   write cost; a sequential scan over the embedding column is fine at this
--   scale (hundreds of docs) and the query uses `<=>` directly. Revisit
--   when the corpus passes ~10k documents.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

ALTER TABLE documents
    ADD COLUMN IF NOT EXISTS embedding vector(128),
    ADD COLUMN IF NOT EXISTS lat DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS lon DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS geom geography(Point, 4326);

CREATE INDEX IF NOT EXISTS documents_title_trgm_idx
    ON documents USING GIN (title gin_trgm_ops);

CREATE INDEX IF NOT EXISTS documents_geom_idx
    ON documents USING GIST (geom);
