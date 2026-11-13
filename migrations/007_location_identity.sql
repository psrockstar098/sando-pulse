-- 007_location_identity.sql
--
-- Locations are identified by (name, kind, county), not (name, kind).
-- Liberia has same-named districts in different counties — Commonwealth
-- exists in Grand Bassa (pop. 35,740), Grand Cape Mount (6,547) and
-- Montserrado (11,876) — so a (name, kind) merge key collapses three
-- real districts into one. The 3.6 seed caught this: 166 rows upserted,
-- only 164 stored.
--
-- Also fixes two 001 leftovers:
--   * the county name typo "River Cess" -> "Rivercess";
--   * the 001 county ids (loc_bomi, ...) -> the slug form the upsert
--     generates (county:bomi), so ON CONFLICT (id) merges with the
--     001 seed instead of duplicating it.
--
-- Idempotent: the name/id updates are no-ops once applied, and the
-- index swap is guarded (a fresh DB already has the new index from
-- 001's corrected file + this migration's CREATE IF NOT EXISTS).

UPDATE locations SET name = 'Rivercess'
  WHERE kind = 'county' AND name = 'River Cess';

UPDATE locations SET id = 'county:' || replace(lower(name), ' ', '_')
  WHERE kind = 'county' AND id LIKE 'loc_%';

-- Rows written by the pre-007 upsert carry ids without the county
-- suffix (city:testville). Recompute them to the new form so the
-- upsert's ON CONFLICT (id) finds them instead of tripping the
-- unique index. The regexp slug matches the Zig slug exactly
-- (drop [^a-z0-9 _-], then map space/dash to '_').
UPDATE locations SET id =
    regexp_replace(regexp_replace(lower(kind), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g') || ':' ||
    regexp_replace(regexp_replace(lower(name), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g') || ':' ||
    regexp_replace(regexp_replace(lower(county), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g')
  WHERE kind <> 'county' AND county IS NOT NULL
    AND id NOT LIKE '%:' || regexp_replace(regexp_replace(lower(county), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g');

DROP INDEX IF EXISTS locations_name_kind_key;

CREATE UNIQUE INDEX IF NOT EXISTS locations_name_kind_county_key
  ON locations (name, kind, county);
