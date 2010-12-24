-- sql/2-entries.sql SQL Migration

SET client_min_messages TO warning;
SET log_min_messages    TO warning;

BEGIN;

CREATE TABLE entries (
    id             TEXT        NOT NULL PRIMARY KEY,
    feed_id        TEXT        NOT NULL REFERENCES feeds(id) ON DELETE CASCADE ON UPDATE CASCADE,
    url            TEXT        NOT NULL,
    via_url        TEXT        NOT NULL DEFAULT '',
    title          TEXT        NOT NULL DEFAULT '',
    published_at   TIMESTAMPTZ NOT NULL,
    updated_at     TIMESTAMPTZ NOT NULL,
    summary        TEXT        NOT NULL DEFAULT '',
    author         TEXT        NOT NULL DEFAULT '',
    enclosure_url  TEXT            NULL DEFAULT NULL,
    enclosure_type TEXT        NOT NULL DEFAULT '',
    enclosure_id   TEXT            NULL DEFAULT NULL,
    enclosure_user TEXT            NULL DEFAULT NULL,
    enclosure_hash TEXT            NULL DEFAULT NULL
);

CREATE INDEX idx_entries_published_at             ON entries(published_at);
CREATE INDEX idx_entry_feed_id                    ON entries(feed_id);
CREATE UNIQUE INDEX idx_entry_feed_enclosure_url  ON entries(enclosure_url);
CREATE UNIQUE INDEX idx_entry_feed_enclosure_id   ON entries(enclosure_id);
CREATE UNIQUE INDEX idx_entry_feed_enclosure_user ON entries(enclosure_user);
CREATE UNIQUE INDEX idx_entry_feed_enclosure_hash ON entries(enclosure_hash);

COMMIT;
