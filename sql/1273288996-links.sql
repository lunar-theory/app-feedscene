-- sql/1273288996-links.sql SQL Migration

CREATE TABLE links (
    url           TEXT PRIMARY KEY,
    portal        TEXT DEFAULT 'text', -- csv, text, pN
    etag          TEXT NOT NULL DEFAULT '',
    last_modified INT  NOT NULL DEFAULT 0
);
