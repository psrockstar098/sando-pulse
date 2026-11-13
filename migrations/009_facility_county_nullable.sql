-- 009_facility_county_nullable.sql
--
-- Two follow-ups to 008:
--   1. Dropping the (name, kind, county) primary key did NOT drop the
--      implicit NOT NULL on county (Postgres keeps it). County must be
--      genuinely nullable for media/government orgs whose existence is
--      verified by homepage but whose county is not.
--   2. 008's id backfill used replace(lower(name), ' ', '_'), which
--      keeps '.' and "'" — but the Zig slug drops every character that
--      is not alphanumeric, space, '-' or '_' ("Jackson F. Doe" ->
--      jackson_f_doe, not jackson_f._doe). Five rows got the wrong id
--      and the upsert's ON CONFLICT (id) missed them. Recompute every
--      facility id with the regexp form, which matches the Zig slug
--      exactly (drop [^a-z0-9 _-], then map space/dash to '_').
--      No-op on databases where 008's backfill already matches.

ALTER TABLE facilities ALTER COLUMN county DROP NOT NULL;

UPDATE facilities SET id =
    regexp_replace(regexp_replace(lower(kind), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g') || ':' ||
    regexp_replace(regexp_replace(lower(name), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g') ||
    CASE WHEN county IS NULL THEN ''
         ELSE ':' || regexp_replace(regexp_replace(lower(county), '[^a-z0-9 _-]', '', 'g'), '[- ]', '_', 'g')
    END;
