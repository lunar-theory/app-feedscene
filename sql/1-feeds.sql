-- sql/1-feeds.sql SQL Migration

SET client_min_messages TO warning;
SET log_min_messages    TO warning;

BEGIN;

CREATE TABLE feeds (
    id         TEXT        NOT NULL PRIMARY KEY,
    url        TEXT        NOT NULL DEFAULT '',
    title      TEXT        NOT NULL DEFAULT '',
    subtitle   TEXT        NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL,
    site_url   TEXT        NOT NULL DEFAULT '',
    icon_url   TEXT        NOT NULL DEFAULT '',
    rights     TEXT        NOT NULL DEFAULT '',
    portal     INT         NOT NULL DEFAULT 0,
    category   TEXT        NOT NULL DEFAULT '',
    fail_count INTEGER     NOT NULL DEFAULT 0
);

COMMIT;
