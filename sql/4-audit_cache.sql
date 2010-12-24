-- sql/4-audit_cache.sql SQL Migration

SET client_min_messages TO warning;
SET log_min_messages    TO warning;

BEGIN;

CREATE TABLE audit_cache (
    id   TEXT PRIMARY KEY,
    url  TEXT NOT NULL DEFAULT ''
);

CREATE INDEX idx_audit_cache_url ON audit_cache(url);

-- CREATE TRIGGER clear_audit_cache BEFORE DELETE ON entries
-- FOR EACH ROW BEGIN
--   DELETE FROM audit_cache
--    WHERE url = OLD.enclosure_url 
--      AND (SELECT COUNT(*) FROM entries WHERE enclosure_url = OLD.enclosure_url) <= 1;
-- END;

COMMIT;