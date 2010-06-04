-- sql/1273288996-feeds.sql SQL Migration

CREATE TABLE feeds (
    url       TEXT PRIMARY KEY,
    title     TEXT NOT NULL DEFAULT '',
    subtitle  TEXT NOT NULL DEFAULT '',
    site_url  TEXT NOT NULL DEFAULT '',
    icon_url  TEXT NOT NULL DEFAULT '',
    rights    TEXT NOT NULL DEFAULT '',
    portal    INT  NOT NULL DEFAULT 0,
    category  TEXT NOT NULL DEFAULT ''
);
