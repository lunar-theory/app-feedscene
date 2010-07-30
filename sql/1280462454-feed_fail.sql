-- sql/1280462454-feed_fail.sql SQL Migration.

ALTER TABLE feeds
  ADD COLUMN fail_count INTEGER NOT NULL DEFAULT 0;
