-- sql/1273288996-feeds.sql SQL Migration

CREATE TABLE feeds (
    url           TEXT PRIMARY KEY,
    portal        INT  NOT NULL DEFAULT 0,
    category      TEXT NOT NULL DEFAULT ''
);
