-- sql/1273288996-links.sql SQL Migration

CREATE TABLE links (
    url           TEXT PRIMARY KEY,
    portal        INT  NOT NULL DEFAULT 0,
    category      TEXT NOT NULL DEFAULT '',
    etag          TEXT NOT NULL DEFAULT '',
    last_modified INT  NOT NULL DEFAULT 0
);
