-- 015_new_dawn_feed_www.sql — source registry fix (2026-11-15).
--
-- The New Dawn's bare-domain feed URL stopped working: the site now
-- 301-redirects https://thenewdawnliberia.com/feed/ to
-- https://www.thenewdawnliberia.com/feed/, and the fetcher does not
-- follow that redirect, so the source failed every fetch
-- ("fetch failed", last success 2026-11-15 13:31). Point the registry
-- at the www host, where the feed answers 200 with valid RSS.
-- The 001 seed is updated in the same change so fresh databases
-- start on the working URL.

UPDATE sources
SET feed_url = 'https://www.thenewdawnliberia.com/feed/'
WHERE id = 'new-dawn';
