# Berkeley Airport Ride Matching: Plan

## Goal

Automatic ride matching for UC Berkeley students going to or from SFO, OAK, and SJC.
A student submits one request. The backend groups them with other students whose
time windows overlap and whose campus locations are close.

Existing apps like BearPool are ride boards: students post rides and browse for one
that fits. This app does the matching instead. Flight tracking and fare splitting
can be added later on top of matching.

## How matching works

1. A student submits a request: airport, direction, departure window, a map pin near
   campus, number of riders, and number of bags.
2. The backend finds other open requests with the same airport and direction,
   an overlapping time window, and a campus point within 1.5 km.
3. Grouping code forms a group of up to 4 people within car capacity, picks a
   departure time inside every member's window, and picks the meeting point with the
   shortest farthest walk. Every member must be within 1 km of that meeting point.
4. Each rider accepts or declines before `respond_by`.
   - Everyone accepts: the group and all its requests become `confirmed`.
   - Anyone declines or doesn't answer: the group is `cancelled` and every member's
     request goes back to `open` to be rematched.

Why the meeting point check is needed: the candidate query compares each rider to one
request only. Two riders can each be 1.5 km from that request and 3 km from each other.
Time windows don't have this problem: if every pair of windows overlaps, all of them
share a common time.

## Data model

Source of truth: `db/schema.sql`. Queries: `db/matching.sql`.
Sample rows: `db/example_data.sql`. The same information with example values is in
`docs/ride_matching_plan.xlsx`.

### Tables

| Table | One row is | Primary key | Foreign keys |
|---|---|---|---|
| `users` | One Berkeley student | `id` | None |
| `meeting_points` | One fixed pickup spot near campus | `id` | None |
| `trip_requests` | One student's request for one ride | `id` | `user_id` -> `users.id` |
| `ride_groups` | One shared ride | `id` | `meeting_point_id` -> `meeting_points.id` |
| `group_members` | One request's place in one group | (`group_id`, `request_id`) | `group_id` -> `ride_groups.id`, `request_id` -> `trip_requests.id` |

Relationships:
- A user has many trip requests.
- A ride group holds 2 to 4 trip requests through `group_members`.
- A request can be in several groups over time if it gets rematched.
- Each ride group uses one meeting point.

### users

| Column | Type | Rules | Stores |
|---|---|---|---|
| `id` | BIGINT identity | Primary key | Unique ID |
| `email` | TEXT | Unique; must end in @berkeley.edu | Login email from Google |
| `name` | TEXT | Required | Name; group pages show first name only |
| `created_at` | TIMESTAMPTZ | Default now() | Signup time |

### meeting_points

| Column | Type | Rules | Stores |
|---|---|---|---|
| `id` | BIGINT identity | Primary key | Unique ID |
| `name` | TEXT | Unique | Name shown to riders, e.g. Sather Gate |
| `location` | GEOGRAPHY(POINT, 4326) | Longitude first | Coordinates |

Filled in by us, not by users. Seed coordinates are approximate; check them on a map.

Seeded points, spread so most riders within 2 km of campus are within 1 km of one:
Downtown Berkeley BART, Sather Gate, North Gate, North Berkeley BART,
Telegraph & Dwight, Clark Kerr Campus.

### trip_requests

| Column | Type | Rules | Stores |
|---|---|---|---|
| `id` | BIGINT identity | Primary key | Unique ID |
| `user_id` | BIGINT | FK -> users.id; cascades on delete | Who submitted it |
| `airport` | TEXT | SFO, OAK, or SJC | Which airport |
| `direction` | TEXT | to_airport or from_airport | Direction |
| `departure_window` | TSTZRANGE | Has start and end; 4 hours or less; no overlap with the same user's active requests | to_airport: when they can leave campus. from_airport: when they can leave the airport |
| `campus_point` | GEOGRAPHY(POINT, 4326) | Never returned to other users | Pickup or drop-off point |
| `riders` | SMALLINT | 1 to 3; default 1 | People on this request |
| `bags` | SMALLINT | 0 to 4; default 1 | Bags, for the capacity check |
| `status` | TEXT | See statuses below; default open | Matching state |
| `created_at` | TIMESTAMPTZ | Default now() | Submit time |
| `updated_at` | TIMESTAMPTZ | App sets on every status change | Last change |

### ride_groups

| Column | Type | Rules | Stores |
|---|---|---|---|
| `id` | BIGINT identity | Primary key | Unique ID |
| `airport` | TEXT | Same as every member | Which airport |
| `direction` | TEXT | Same as every member | Direction |
| `departure_time` | TIMESTAMPTZ | Inside every member's window | When the group leaves |
| `meeting_point_id` | BIGINT | FK -> meeting_points.id; every member within 1 km | Where they meet |
| `status` | TEXT | proposed, confirmed, cancelled | Group state |
| `respond_by` | TIMESTAMPTZ | 2 hours after creation, no later than 1 hour before departure | Accept deadline |
| `created_at` | TIMESTAMPTZ | Default now() | When matching created it |

### group_members

| Column | Type | Rules | Stores |
|---|---|---|---|
| `group_id` | BIGINT | PK part 1; FK -> ride_groups.id | Which group |
| `request_id` | BIGINT | PK part 2; FK -> trip_requests.id | Which request |
| `response` | TEXT | pending, accepted, declined | Rider's answer |
| `responded_at` | TIMESTAMPTZ | NULL until answered | When they answered |

### Request statuses

| Status | Meaning | Set by |
|---|---|---|
| `open` | Waiting to be matched | New request, or its group was cancelled |
| `proposed` | In a group, waiting on accepts | Matching |
| `confirmed` | Whole group accepted | Last member's accept |
| `cancelled` | User cancelled | Cancel endpoint |
| `expired` | Window ended without a match | Scheduled job |

### Constraints and indexes

- CHECK constraints on every fixed-value column and on the window length.
- Exclusion constraint on (`user_id`, `departure_window`) for active requests.
- GiST index on (`airport`, `direction`, `departure_window`) for open requests.
- GiST index on `campus_point` for open requests.
- Index on `group_members.request_id`.
- Group creation runs in one transaction that locks the chosen requests with
  `FOR UPDATE SKIP LOCKED`, so two matcher runs can't put one rider in two groups.

## Why PostgreSQL

1. **Time windows.** `TSTZRANGE` stores a window as one value. `&&` checks overlap
   using an index. An exclusion constraint blocks duplicate active requests.
2. **Location.** PostGIS adds the `GEOGRAPHY` type, `ST_DWithin`, and `ST_Distance`,
   which measure meters and use spatial indexes.
3. **Concurrency and data integrity.** Transactions, row locks, foreign keys, and
   CHECK constraints.
4. **Relational data.** Users, requests, and groups reference each other by ID.

Resume summary: "I used PostgreSQL because matching depends on time-window overlap and
geographic distance. Postgres handles both with indexed queries through range types and
PostGIS, and transactions prevent a rider from being placed in two groups."

The host must support the PostGIS extension.

## Minimum features (v1)

| Feature | Endpoint | Reads and writes |
|---|---|---|
| Sign in with a Berkeley Google account | Google OAuth callback | Looks up user by email; inserts on first login; rejects non-@berkeley.edu |
| Submit a ride request | `POST /requests` | Inserts a `trip_requests` row with status open, then runs matching |
| Cancel a request | `POST /requests/{id}/cancel` | Sets status cancelled. If it was in a proposed group, cancels the group and sets the other members back to open |
| Automatic matching | Runs after each new request | Reads open requests and meeting points. Inserts a `ride_groups` row and one `group_members` row per request (pending). Sets requests to proposed |
| Accept a group | `POST /groups/{id}/accept` | Sets response accepted. When all accept, group and requests become confirmed |
| Decline a group | `POST /groups/{id}/decline` | Sets response declined. Cancels the group and sets every member's request back to open |
| My rides page | `GET /me/groups` | Reads the user's requests; for each group: departure time, meeting point name, members' responses and first names. Never returns `campus_point` |
| Scheduled job, every few minutes | None | Expires open requests whose window ended. Sets pending invites past `respond_by` to declined and handles them like a decline |

Frontend screens: request form with a map pin, "finding matches" status, group page
(departure time, meeting point, members), and My rides.

### Example request

The frontend sends this after sign-in. The session cookie identifies the user.

```http
POST /requests
Content-Type: application/json

{
  "airport": "SFO",
  "direction": "to_airport",
  "window_start": "2026-11-06T14:00:00-08:00",
  "window_end": "2026-11-06T16:00:00-08:00",
  "lat": 37.8690,
  "lng": -122.2600,
  "riders": 1,
  "bags": 1
}
```

Response:

```json
{ "id": 1, "status": "open" }
```

## API keys and secrets

Two meanings of "API" in this project:
- **Our API**: the endpoints above. Users authenticate with Google sign-in and a
  session cookie. No API key.
- **Outside APIs**: services our app calls. These need credentials.

| Credential | Used for | Public or secret | Needed in v1 |
|---|---|---|---|
| Google OAuth client ID | Google sign-in screen | Public | Yes |
| Google OAuth client secret | Backend completes sign-in | Secret, server only | Yes |
| Map token (Mapbox or Google Maps) | Map for the pin drop | Public, restricted to our domains | Only if not using Leaflet + OpenStreetMap |
| Flight status API key | Flight tracking | Secret, server only | No (feature 2) |
| `DATABASE_URL` | Postgres connection | Secret, server only | Yes |
| `SESSION_SECRET` | Signs session cookies | Secret, server only | Yes |

Matching uses no outside API. PostGIS computes distances in the database.

Rules:
- Secrets stay on the server in environment variables.
- Frontend variables with a public prefix (`VITE_` in Vite, `NEXT_PUBLIC_` in Next.js)
  are bundled into browser code. Only public values get that prefix.
- `.env` is in `.gitignore`. `.env.example` lists names with no values.
- Production values go in the host's environment settings.
- Restrict public keys to `localhost` and the deployed URL in each provider's dashboard.
- If a secret is pushed to GitHub, rotate it. Deleting the commit is not enough.
- Google's `hd=berkeley.edu` parameter only filters the login screen. The backend must
  check the `hd` claim and email in the verified ID token.

## Privacy rules

- `campus_point` is close to where a student lives. The API never returns it to other
  users. Group pages show the meeting point and first names only.
- Delete `campus_point` after the trip.
- Only @berkeley.edu accounts.

## Not in v1

Chat, flight tracking, fare splitting, push notifications, gender preference filter.
In v1, users check the My rides page for updates.

## Open decisions

- Backend framework (FastAPI or Express were the options considered) and frontend framework.
- Map: Leaflet + OpenStreetMap (no key) or Mapbox / Google Maps.
- How confirmed riders contact each other. Simplest option: show confirmed members'
  Berkeley emails on the group page. No new table needed.
- The bag limit per car. The capacity check lives in the grouping code.
- After a decline, how to keep the grouping code from proposing the same group again.
- Hosting with PostGIS support.

## Build order

1. Schema, meeting points, and a seed script that generates about 200 fake requests,
   so matching can be tested without real users.
2. Matching and grouping logic with unit tests.
3. Google sign-in.
4. API endpoints.
5. Frontend.
6. Deploy.

The seed data gives a resume number, such as "matched 85% of simulated requests into
groups of 3+". Measure the real number; don't use this example.
