CREATE TABLE third (
  id int,
  second_id int references second(id)
);
