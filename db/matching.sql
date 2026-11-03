-- matching.sql
-- Queries for the matcher. Values like :id are placeholders your app fills in
-- (for example with SQLAlchemy text() or your driver's parameter binding).


-- 1. CANDIDATES: open requests that could share a ride with request :id
SELECT other.id,
       other.riders,
       other.bags,
       other.departure_window,
       ST_Distance(other.campus_point, me.campus_point) AS meters_apart
FROM trip_requests me
JOIN trip_requests other
  ON other.id <> me.id
 AND other.user_id <> me.user_id                            -- not the same person
 AND other.status = 'open'                                  -- not already in a group
 AND other.airport = me.airport                             -- same airport
 AND other.direction = me.direction                         -- same direction
 AND other.departure_window && me.departure_window          -- windows overlap
 AND upper(other.departure_window) > now()                  -- window hasn't ended
 AND ST_DWithin(other.campus_point, me.campus_point, 1500)  -- within 1.5 km of me
WHERE me.id = :id
  AND me.status = 'open'
ORDER BY meters_apart;

-- This compares each candidate to ME only. Two candidates can each be 1.5 km
-- from me and 3 km from each other. Query 2 fixes that by checking every
-- member against one meeting point. Time windows don't have this problem:
-- if every pair of windows overlaps, all of them share a common time.


-- 2. MEETING POINT: the spot that minimizes the farthest walk in a proposed group
SELECT mp.id,
       mp.name,
       max(ST_Distance(mp.location, tr.campus_point)) AS farthest_walk_m
FROM meeting_points mp
CROSS JOIN trip_requests tr
WHERE tr.id = ANY(:group_request_ids)
GROUP BY mp.id, mp.name
HAVING max(ST_Distance(mp.location, tr.campus_point)) <= 1000   -- nobody walks more than 1 km
ORDER BY farthest_walk_m
LIMIT 1;
-- No row returned = this set of riders can't share a meeting point; try a smaller group.


-- 3. CREATE THE GROUP inside one transaction.
--    Row locks stop two matcher runs from putting the same rider in two groups.
BEGIN;

-- Lock the chosen requests. SKIP LOCKED leaves out rows another run already holds.
SELECT id
FROM trip_requests
WHERE id = ANY(:group_request_ids)
  AND status = 'open'
FOR UPDATE SKIP LOCKED;
-- App code: if fewer rows come back than you asked for, ROLLBACK and regroup.

INSERT INTO ride_groups (airport, direction, departure_time, meeting_point_id, respond_by)
VALUES (
  :airport,
  :direction,
  :departure_time,
  :meeting_point_id,
  -- 2 hours to respond, but never later than 1 hour before departure
  LEAST(now() + interval '2 hours', CAST(:departure_time AS timestamptz) - interval '1 hour')
)
RETURNING id;   -- use this as :group_id below

INSERT INTO group_members (group_id, request_id)
SELECT :group_id, unnest(CAST(:group_request_ids AS bigint[]));

UPDATE trip_requests
SET status = 'proposed', updated_at = now()
WHERE id = ANY(:group_request_ids);

COMMIT;


-- 4. EXPIRE requests whose window ended. Run every few minutes from a scheduled job.
UPDATE trip_requests
SET status = 'expired', updated_at = now()
WHERE status = 'open'
  AND upper(departure_window) <= now();


-- 5. TIME OUT invites nobody answered. Same scheduled job.
UPDATE group_members gm
SET response = 'declined', responded_at = now()
FROM ride_groups g
WHERE gm.group_id = g.id
  AND g.status = 'proposed'
  AND g.respond_by <= now()
  AND gm.response = 'pending';
-- App code then cancels those groups and sets the remaining members'
-- requests back to 'open' so they get rematched.
