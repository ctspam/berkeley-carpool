-- example_data.sql
-- Sample rows for local testing. Run after schema.sql.
-- Three students are matched into one SFO ride at Sather Gate (meeting point 2).
-- A fourth student has an open OAK request. All names and emails are made up.
-- OVERRIDING SYSTEM VALUE lets us set the ids so the rows reference each other.

INSERT INTO users (id, email, name, created_at) OVERRIDING SYSTEM VALUE VALUES
 (1,'maya.chen@berkeley.edu','Maya Chen','2026-11-02 09:12-08'),
 (2,'jordan.lee@berkeley.edu','Jordan Lee','2026-11-02 18:40-08'),
 (3,'sam.patel@berkeley.edu','Sam Patel','2026-11-03 11:05-08'),
 (4,'ava.garcia@berkeley.edu','Ava Garcia','2026-11-04 08:30-08');
INSERT INTO trip_requests (id,user_id,airport,direction,departure_window,campus_point,riders,bags,status,created_at,updated_at) OVERRIDING SYSTEM VALUE VALUES
 (1,1,'SFO','to_airport','["2026-11-06 14:00-08","2026-11-06 16:00-08")','POINT(-122.2600 37.8690)',1,1,'proposed','2026-11-04 09:00-08','2026-11-05 08:45-08'),
 (2,2,'SFO','to_airport','["2026-11-06 14:30-08","2026-11-06 16:30-08")','POINT(-122.2650 37.8680)',1,1,'proposed','2026-11-04 13:20-08','2026-11-05 08:45-08'),
 (3,3,'SFO','to_airport','["2026-11-06 13:30-08","2026-11-06 15:30-08")','POINT(-122.2550 37.8720)',2,2,'proposed','2026-11-05 08:45-08','2026-11-05 08:45-08'),
 (4,4,'OAK','from_airport','["2026-11-08 18:00-08","2026-11-08 20:00-08")','POINT(-122.2580 37.8650)',1,1,'open','2026-11-05 09:30-08','2026-11-05 09:30-08');
INSERT INTO ride_groups (id,airport,direction,departure_time,meeting_point_id,status,respond_by,created_at) OVERRIDING SYSTEM VALUE VALUES
 (1,'SFO','to_airport','2026-11-06 15:00-08',2,'proposed','2026-11-05 10:45-08','2026-11-05 08:45-08');

-- Maya (request 1) and Sam (request 3) accepted; Jordan (request 2) hasn't answered
INSERT INTO group_members VALUES (1,1,'accepted','2026-11-05 09:10-08'),(1,2,'pending',NULL),(1,3,'accepted','2026-11-05 09:02-08');

-- Move identity counters past the sample ids so new rows don't collide
SELECT setval(pg_get_serial_sequence('users', 'id'), 4);
SELECT setval(pg_get_serial_sequence('trip_requests', 'id'), 4);
SELECT setval(pg_get_serial_sequence('ride_groups', 'id'), 1);
