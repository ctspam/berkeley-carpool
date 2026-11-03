# Berkeley Airport Ride Matching

Read docs/plan.md before starting work. It has the full plan: data model, matching
rules, endpoints, API keys, privacy rules, open decisions, and build order.

## Project

Web app that automatically matches UC Berkeley students into shared rides to and from
SFO, OAK, and SJC. Version 1 is one feature: automatic ride matching.

## Files

- db/schema.sql: data model. Source of truth for tables.
- db/matching.sql: candidate, meeting point, group creation, and cleanup queries.
- db/example_data.sql: 4 users, 4 requests, 1 group, for local testing.
- docs/plan.md: full plan.
- docs/ride_matching_plan.xlsx: same plan as a spreadsheet, with example values.
- .env.example: environment variable names.

## Stack

- PostgreSQL 14+ with the PostGIS and btree_gist extensions.
- Backend and frontend frameworks are not chosen yet. Ask before picking one.

## Rules

- Add inline comments to code.
- Write docs and comments plain and concise.
- When changing a table, update db/schema.sql and docs/plan.md together.
- ST_MakePoint takes (longitude, latitude).
- Never return trip_requests.campus_point to other users. Group pages show the
  meeting point and first names only.
- Only @berkeley.edu accounts. Verify the hd claim and email from the Google ID token
  on the server.
- Secrets (DATABASE_URL, GOOGLE_CLIENT_SECRET, SESSION_SECRET) stay on the server.
  Only public values get the frontend's public prefix (VITE_ or NEXT_PUBLIC_).
- Never commit .env.
- Group creation runs in one transaction with FOR UPDATE SKIP LOCKED
  (see db/matching.sql).
