-- 012_source_registry_fix.sql — source registry corrections (2026-11-13).
-- FrontPage Africa re-enabled (a browser User-Agent defeats the Cloudflare
-- bot check — see fetchers.zig); KMTV moved to its new home mykmtvnews.com;
-- The Analyst and Local Voices Liberia added (both verified live RSS feeds).
-- Bush Chicken, New Republic and Spoon TV stay disabled with the true
-- current reason: their websites are gone (parked domains / closed network),
-- not the feeds. Upserts so already-migrated DBs get the corrections and
-- fresh installs reach the same final state on top of 001's seed.
-- (Without this, document and health inserts for the new sources fail the
-- sources(id) foreign key — seen live 2026-11-13 as PgServerError on the
-- the-analyst and local-voices health records.)
INSERT INTO sources (id, name, home_url, feed_url, reliability, enabled, disabled_reason) VALUES
  ('frontpage-africa', 'FrontPage Africa', 'https://frontpageafricaonline.com/', 'https://frontpageafricaonline.com/feed/', 0.70, TRUE, NULL),
  ('kmtv', 'KMTV', 'https://mykmtvnews.com/', 'https://mykmtvnews.com/feed/', 0.70, TRUE, NULL),
  ('the-analyst', 'The Analyst', 'https://analystliberiaonline.com/', 'https://analystliberiaonline.com/feed/', 0.70, TRUE, NULL),
  ('local-voices', 'Local Voices Liberia', 'https://localvoicesliberia.com/', 'https://localvoicesliberia.com/feed/', 0.70, TRUE, NULL),
  ('spoon-tv', 'Spoon TV', 'https://www.spoonfmradio.com/', 'https://www.spoonfmradio.com/feed/', 0.70, FALSE, 'Website parked; network closed by court order Jul 2023, live presence is Facebook only (needs the Meta app) (verified 2026-11-13)'),
  ('bush-chicken', 'Bush Chicken', 'https://bushchicken.com/', 'https://bushchicken.com/feed/', 0.70, FALSE, 'Domain parked (parking lander page, no site) (verified 2026-11-13)'),
  ('new-republic', 'New Republic', 'https://www.newrepublicliberia.com/', 'https://www.newrepublicliberia.com/feed/', 0.70, FALSE, 'Domain parked (resolves to a parking IP; connection fails) (verified 2026-11-13)')
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  home_url = EXCLUDED.home_url,
  feed_url = EXCLUDED.feed_url,
  reliability = EXCLUDED.reliability,
  enabled = EXCLUDED.enabled,
  disabled_reason = EXCLUDED.disabled_reason;
