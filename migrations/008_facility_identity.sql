-- 008_facility_identity.sql
--
-- Facilities are identified by a slug id (kind:name[:county]), not by
-- the (name, kind, county) primary key. A primary-key column is
-- implicitly NOT NULL, so the old PK forced every facility to carry a
-- county — but the 3.6 seed verifies some organizations by their
-- official homepage (media + government), which proves the
-- organization exists, not its street address. Forcing a county there
-- would mean inventing one. With a surrogate id, county is genuinely
-- optional; the unique index still keeps (name, kind, county) unique
-- where a county is known, and the id (which encodes the county when
-- present) is the upsert arbiter.
--
-- Idempotent: the column add + id backfill + PK swap run once per
-- database (tracked in schema_migrations); on an empty facilities
-- table the backfill is a no-op.

ALTER TABLE facilities DROP CONSTRAINT facilities_pkey;

ALTER TABLE facilities ADD COLUMN id TEXT;

UPDATE facilities SET id =
    regexp_replace(regexp_replace(lower(kind), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g') || ':' ||
    regexp_replace(regexp_replace(lower(name), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g') ||
    CASE WHEN county IS NULL THEN ''
         ELSE ':' || regexp_replace(regexp_replace(lower(county), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g')
    END;

ALTER TABLE facilities ALTER COLUMN id SET NOT NULL;

ALTER TABLE facilities ADD PRIMARY KEY (id);

CREATE UNIQUE INDEX IF NOT EXISTS facilities_name_kind_county_key
  ON facilities (name, kind, county);
