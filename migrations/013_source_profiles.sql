-- 013_source_profiles.sql — Trust & Intelligence Engine, Phase 1
-- (2026-11-14). Source profiles + county categorization.
--
-- `source_profiles` mirrors the compiled-in profiles
-- (src/intelligence/trust/source_registry.zig) so the database holds
-- the same profile data the API serves. `county` is the outlet's BASE
-- county (headquarters): all 12 registry sources are national outlets
-- headquartered in Monrovia, Montserrado; their coverage is national.
-- Every county except Montserrado honestly has zero sources until
-- Phase 2's county-level discovery registers genuine county sources.
-- `county_confidence` is "unverified" for Local Voices Liberia only:
-- its newsroom base is not stated on its site (see the registry
-- module's county_note). `reliability` is the registry's design-doc
-- grade (news 0.70), NOT a computed credibility score — the 1-5 score
-- is Phase 4. No verdicts anywhere in this schema.
--
-- `source_profile_history` is the audit trail (one row per registry
-- change). The seed below records one `profile_created` row per
-- source, guarded by NOT EXISTS so re-running the migration is a
-- no-op; future phases append real change rows here.

CREATE TABLE IF NOT EXISTS source_profiles (
    source_id TEXT PRIMARY KEY REFERENCES sources(id),
    platform TEXT NOT NULL,
    county TEXT NOT NULL,
    county_confidence TEXT NOT NULL DEFAULT 'verified',
    county_note TEXT NOT NULL DEFAULT '',
    district TEXT,
    community TEXT,
    scope TEXT NOT NULL DEFAULT 'national',
    coverage TEXT[] NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'active',
    reliability REAL NOT NULL DEFAULT 0.70,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS source_profile_history (
    id BIGSERIAL PRIMARY KEY,
    source_id TEXT NOT NULL REFERENCES sources(id),
    action TEXT NOT NULL,
    detail TEXT NOT NULL,
    at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO source_profiles (source_id, platform, county, county_confidence, county_note, district, community, scope, coverage, status, reliability) VALUES
  ('frontpage-africa', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'active', 0.70),
  ('daily-observer', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'active', 0.70),
  ('new-dawn', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'active', 0.70),
  ('liberian-investigator', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'active', 0.70),
  ('gnn-liberia', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'active', 0.70),
  ('kmtv', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'active', 0.70),
  ('spoon-tv', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'removed', 0.70),
  ('bush-chicken', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'removed', 0.70),
  ('new-republic', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'removed', 0.70),
  ('the-analyst', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'active', 0.70),
  ('local-voices', 'news', 'Montserrado', 'unverified', 'Community-reporter network; newsroom base not stated on the outlet''s site — recorded as Montserrado (Monrovia media hub) pending verification. Coverage is county-level via community reporters.', NULL, NULL, 'county', ARRAY['general'], 'active', 0.70),
  ('the-news', 'news', 'Montserrado', 'verified', 'National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.', NULL, NULL, 'national', ARRAY['general'], 'active', 0.70)
ON CONFLICT (source_id) DO UPDATE SET
  platform = EXCLUDED.platform,
  county = EXCLUDED.county,
  county_confidence = EXCLUDED.county_confidence,
  county_note = EXCLUDED.county_note,
  district = EXCLUDED.district,
  community = EXCLUDED.community,
  scope = EXCLUDED.scope,
  coverage = EXCLUDED.coverage,
  status = EXCLUDED.status,
  reliability = EXCLUDED.reliability,
  updated_at = now();

INSERT INTO source_profile_history (source_id, action, detail)
SELECT s.id, 'profile_created', 'Source profile created (Trust & Intelligence Engine, Phase 1)'
FROM sources s
WHERE NOT EXISTS (
    SELECT 1 FROM source_profile_history h
    WHERE h.source_id = s.id AND h.action = 'profile_created'
);
