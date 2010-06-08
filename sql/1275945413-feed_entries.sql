-- sql/1275945413-feed_entries.sql SQL Migration

CREATE VIEW feed_entries AS
SELECT e.id, e.url, e.title, e.published_at, e.updated_at, e.summary,
       e.author, e.enclosure_url, e.enclosure_type, e.feed_id, f.portal,
       f.url AS feed_url, f.title AS feed_title, f.subtitle AS feed_subtitle,
       f.site_url, f.icon_url, f.updated_at AS feed_updated_at, f.rights
  FROM feeds f
  JOIN entries e ON f.id = e.feed_id;
