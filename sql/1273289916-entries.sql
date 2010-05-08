-- sql/1273289916-entries.sql SQL Migration

CREATE TABLE entries (
    id             TEXT     PRIMARY KEY,
    title_type     TEXT     NOT NULL DEFAULT 'text',
    title          TEXT     NOT NULL DEFAULT '',
    url            TEXT     NOT NULL,
    feed_url       TEXT     NOT NULL REFERENCES links(url),
    published_at   DATETIME NOT NULL,
    updated_at     DATETIME NOT NULL,
    summary_type   TEXT     NOT NULL DEFAULT 'text',
    summary        TEXT     NOT NULL DEFAULT '',
    author_name    TEXT     NOT NULL DEFAULT '',
    author_email   TEXT     NOT NULL DEFAULT '',
    author_uri     TEXT     NOT NULL DEFAULT '',
    portal         TEXT     NOT NULL DEFAULT 'text',
    enclosure_url  TEXT     NOT NULL DEFAULT '',
    enclosure_type TEXT     NOT NULL DEFAULT ''
);

CREATE INDEX idx_entries_published_at ON entries(published_at);
