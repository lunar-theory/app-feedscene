SET client_min_messages TO warning;
SET log_min_messages    TO warning;
CREATE TABLE second (
  id int PRIMARY KEY,
  first_id int references first(id)
);
