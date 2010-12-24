SET client_min_messages TO warning;
SET log_min_messages    TO warning;
CREATE TABLE third (
  id int PRIMARY KEY,
  second_id int references second(id)
);
