-- sql/1273288996-feeds.sql SQL Migration

CREATE TABLE feeds (
    url           TEXT PRIMARY KEY,
    name          TEXT NOT NULL DEFAULT '',
    site_url      TEXT NOT NULL DEFAULT '',
    portal        INT  NOT NULL DEFAULT 0,
    category      TEXT NOT NULL DEFAULT ''
);
