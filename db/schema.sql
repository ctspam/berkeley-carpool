-- schema.sql
-- Data model for automatic airport ride matching (Berkeley <-> SFO / OAK / SJC).
-- Requires PostgreSQL 14+ with the PostGIS extension.

CREATE EXTENSION IF NOT EXISTS postgis;     -- GEOGRAPHY type and distance functions
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- lets one GiST index mix = columns with ranges

-- Students who can use the app
CREATE TABLE users (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email      TEXT NOT NULL UNIQUE
             CHECK (lower(email) LIKE '%@berkeley.edu'),   -- Berkeley accounts only
  name       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Fixed pickup / drop-off spots that groups meet at
CREATE TABLE meeting_points (
  id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name     TEXT NOT NULL UNIQUE,                 -- e.g. 'Downtown Berkeley BART'
  location GEOGRAPHY(POINT, 4326) NOT NULL       -- 4326 = standard GPS lat/lng
);

-- One row per student looking for a ride
CREATE TABLE trip_requests (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id          BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  airport          TEXT NOT NULL CHECK (airport IN ('SFO', 'OAK', 'SJC')),
  direction        TEXT NOT NULL CHECK (direction IN ('to_airport', 'from_airport')),

  -- to_airport:   when the rider can leave campus
  -- from_airport: when the rider can leave the airport (after landing and bags)
  departure_window TSTZRANGE NOT NULL,

  -- Pickup point (to_airport) or drop-off point (from_airport).
  -- Never returned to other riders; the API only shows the meeting point.
  campus_point     GEOGRAPHY(POINT, 4326) NOT NULL,

  riders           SMALLINT NOT NULL DEFAULT 1 CHECK (riders BETWEEN 1 AND 3),  -- people on this request
  bags             SMALLINT NOT NULL DEFAULT 1 CHECK (bags BETWEEN 0 AND 4),

  -- open -> proposed (placed in a group, waiting on accepts) -> confirmed
  -- open or proposed -> cancelled (by the user) or expired (window ended)
  status           TEXT NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open', 'proposed', 'confirmed', 'cancelled', 'expired')),

  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Window must have a start and an end and be 4 hours or less,
  -- so one very wide window can't match everyone
  CONSTRAINT window_is_bounded CHECK (
    NOT isempty(departure_window)
    AND NOT lower_inf(departure_window)
    AND NOT upper_inf(departure_window)
    AND upper(departure_window) - lower(departure_window) <= interval '4 hours'
  ),

  -- A user can't hold two active requests with overlapping windows
  CONSTRAINT one_active_request_per_window EXCLUDE USING gist (
    user_id WITH =,
    departure_window WITH &&
  ) WHERE (status IN ('open', 'proposed', 'confirmed'))
);

-- Matching filters on airport + direction + window, and only open rows matter
CREATE INDEX trip_requests_match_idx
  ON trip_requests USING gist (airport, direction, departure_window)
  WHERE status = 'open';

-- Distance checks between open requests
CREATE INDEX trip_requests_point_idx
  ON trip_requests USING gist (campus_point)
  WHERE status = 'open';

-- A proposed or confirmed shared ride
CREATE TABLE ride_groups (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  airport          TEXT NOT NULL CHECK (airport IN ('SFO', 'OAK', 'SJC')),
  direction        TEXT NOT NULL CHECK (direction IN ('to_airport', 'from_airport')),
  departure_time   TIMESTAMPTZ NOT NULL,     -- must fall inside every member's window
  meeting_point_id BIGINT NOT NULL REFERENCES meeting_points(id),
  status           TEXT NOT NULL DEFAULT 'proposed'
                   CHECK (status IN ('proposed', 'confirmed', 'cancelled')),
  respond_by       TIMESTAMPTZ NOT NULL,     -- unanswered invites count as declines after this
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Links requests (not users) to groups, so the group can read
-- each member's rider count and bags for the capacity check
CREATE TABLE group_members (
  group_id     BIGINT NOT NULL REFERENCES ride_groups(id) ON DELETE CASCADE,
  request_id   BIGINT NOT NULL REFERENCES trip_requests(id) ON DELETE CASCADE,
  response     TEXT NOT NULL DEFAULT 'pending'
               CHECK (response IN ('pending', 'accepted', 'declined')),
  responded_at TIMESTAMPTZ,
  PRIMARY KEY (group_id, request_id)
);

-- Look up every group a request has been in (for "my rides" and rematching)
CREATE INDEX group_members_request_idx ON group_members (request_id);

-- Example meeting points. Coordinates are approximate; check them on a map.
-- ST_MakePoint takes (longitude, latitude): longitude first.
INSERT INTO meeting_points (name, location) VALUES
  ('Downtown Berkeley BART', ST_SetSRID(ST_MakePoint(-122.2681, 37.8700), 4326)::geography),
  ('Sather Gate',            ST_SetSRID(ST_MakePoint(-122.2595, 37.8703), 4326)::geography);
