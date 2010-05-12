CREATE TABLE second (
  id int,
  first_id int references first(id)
);
