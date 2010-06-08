-- sql/1273288996-feeds.sql SQL Migration

CREATE TABLE feeds (
    id         TEXT     NOT NULL PRIMARY KEY,
    url        TEXT     NOT NULL DEFAULT '',
    title      TEXT     NOT NULL DEFAULT '',
    subtitle   TEXT     NOT NULL DEFAULT '',
    updated_at DATETIME NOT NULL,
    site_url   TEXT     NOT NULL DEFAULT '',
    icon_url   TEXT     NOT NULL DEFAULT '',
    rights     TEXT     NOT NULL DEFAULT '',
    portal     INT      NOT NULL DEFAULT 0,
    category   TEXT     NOT NULL DEFAULT ''
);
