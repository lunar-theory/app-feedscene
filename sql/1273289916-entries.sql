-- sql/1273289916-entries.sql SQL Migration

CREATE TABLE entries (
    id             TEXT     PRIMARY KEY,
    portal         INT      NOT NULL DEFAULT 0,
    feed_id        TEXT     NOT NULL REFERENCES feeds(id) ON DELETE CASCADE ON UPDATE CASCADE,
    url            TEXT     NOT NULL,
    title          TEXT     NOT NULL DEFAULT '',
    published_at   DATETIME NOT NULL,
    updated_at     DATETIME NOT NULL,
    summary        TEXT     NOT NULL DEFAULT '',
    author         TEXT     NOT NULL DEFAULT '',
    enclosure_url  TEXT     NOT NULL DEFAULT '',
    enclosure_type TEXT     NOT NULL DEFAULT ''
);

CREATE INDEX idx_entries_portal_published_at ON entries(portal, published_at);
