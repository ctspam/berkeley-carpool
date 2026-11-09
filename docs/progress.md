# Progress report: automatic ride matching

What's done, what's next, what was hard, and why the design looks the way it does.
Branch: `matching`. As of 2026-11-09. Task details are in `docs/tasks.md`; known
problems are in `docs/known-issues.md`.

## Where things stand

| Phase | Tasks | Status |
|---|---|---|
| 1. Database | 1 to 3 | Done |
| 2. Python project | 4 to 6 | Done |
| 3. Fake data | 7 to 8 | Done |
| 4. The matcher | 9 to 13 | Next |
| 5. Measure it | 14 | Not started |
| Commit work | 15 | Ongoing (one commit per task) |

## What I did, task by task

### Phase 1: Database

**Task 1: Postgres + PostGIS in Docker.** Runs the database in a container named
`carpool-db` (`postgis/postgis:16-3.4`, port 5432), so nothing is installed on the Mac
itself and the database can be thrown away and rebuilt.

**Task 2: Load the schema.** `db/schema.sql` creates 5 tables:

| Table | One row is |
|---|---|
| `users` | A Berkeley student |
| `meeting_points` | A fixed pickup spot near campus |
| `trip_requests` | One student's request for one ride |
| `ride_groups` | One shared ride |
| `group_members` | One request's place in one group |

`db/example_data.sql` adds 4 users, 4 requests and 1 group to test with.

**Task 3: Run the matching queries by hand.** Ran query 1 (candidates) from
`db/matching.sql`, added my own OAK request near an example rider, and checked that it
came back with its distance. Then ran query 2 (meeting point) on the pair. The point was
to understand what each query returns before calling it from Python.

### Phase 2: Python project

**Task 4: `.env`.** Holds `DATABASE_URL`. It's gitignored; `.env.example` lists the
variable names with no values.

**Task 5: uv project.** `pyproject.toml` with `psycopg[binary]` (Postgres driver) and
`pytest` (tests). Commit `66ac51a`.

**Task 6: Connection helper.** `src/carpool/db.py` has `connect()`, which reads
`DATABASE_URL` and opens a connection. If the variable is missing, it raises a clear
error that says how to run with `--env-file .env`, instead of an unclear psycopg error.
Commit `2121309`.

### Phase 3: Fake data (done with Claude's help)

**Task 7: More meeting points.** Went from 2 points (both downtown) to 6:
Downtown Berkeley BART, Sather Gate, North Gate, North Berkeley BART,
Telegraph & Dwight, Clark Kerr Campus. Updated `db/schema.sql` and `docs/plan.md`
together. Commit `3e5d015`.

**Task 8: Seed script.** `scripts/seed.py` generates 200 fake users, each with one
open request. Commit `6417e53`. Result:

| Check | Result |
|---|---|
| Airports | SFO 91, OAK 75, SJC 39 |
| Direction | 143 to the airport, 62 from the airport |
| Riders per request | 1: 157, 2: 39, 3: 9 |
| Window length | 1 to 4 hours |
| Distance from campus | average 1.36 km, max 1.98 km |
| Within 1 km of a meeting point | 130 of 205 (63%) |

Run it with `uv run --env-file .env python scripts/seed.py --reset`.
Running `--reset` twice still leaves exactly 200 fake users.

## What was hard

- **Moving the project folder.** The project started in `~/Downloads` and moved to
  `~/Documents`. Things kept pointing at the old path: the shell's `VIRTUAL_ENV`, and
  the `claude` command, which stopped running with "Permission denied".
- **Environment variables.** `connect()` failed until I learned that `uv run` doesn't
  load `.env` by itself; you have to pass `--env-file .env`. That's why `db.py` now
  explains this in its error message.
- **Git vs GitHub.** Commits didn't show on GitHub until the branch was pushed.
  Committing only saves locally.
- **Docker shutting down uncleanly.** Postgres refused to start because of stale lock
  files left from Nov 4. My data was fine; the lock files had to be cleared
  (steps in `docs/known-issues.md` #5).
- **Python couldn't find my own package.** macOS hid the `.pth` file that points Python
  at `src/`, and Python 3.13 skips hidden ones. Workaround in `docs/known-issues.md` #3.
- **Understanding the 63% coverage.** At first it looked like the app just needed more
  users. It doesn't: riders more than 1 km from every meeting point can never be
  grouped, no matter how many other users there are. It depends on where the points
  are, not on demand.

## Design choices and why

### Database

- **PostgreSQL + PostGIS.** Matching comes down to two questions: do the time windows
  overlap, and are the riders close? Postgres answers the first with range types and
  PostGIS answers the second with distances in meters, both using indexes. Transactions
  and row locks also stop two matcher runs from putting one rider in two groups.
- **`departure_window` is one `TSTZRANGE`, not two columns.** `&&` checks overlap in
  one step, and it allows an exclusion constraint.
- **Exclusion constraint: one active request per time.** A user can't have two
  open/proposed/confirmed requests with overlapping windows. The database enforces it,
  so app bugs can't get around it.
- **Windows are capped at 4 hours.** One very wide window would match everyone and make
  groups that don't really work.
- **Partial GiST indexes (`WHERE status = 'open'`).** Matching only ever looks at open
  requests, so the indexes skip old ones and stay small.
- **`group_members` links requests, not users.** The group needs each member's
  `riders` and `bags` for the car capacity check, and those live on the request.
  It also lets a request be rematched into a new group after a decline.
- **Status values are fixed by CHECK constraints.** For example, a request is
  open → proposed → confirmed, or cancelled/expired. A typo can't create a new status.
- **`@berkeley.edu` is checked in the database too,** not just at login.

### Matching rules

- **Two distance limits: 1.5 km between riders, 1 km to the meeting point.** The
  candidate query compares everyone to one rider only, so two candidates could each be
  1.5 km from that rider but 3 km from each other. The meeting point check (everyone
  within 1 km of one spot) fixes that. Time windows don't need this extra check: if every
  pair overlaps, they all share a common time.
- **Fixed meeting points instead of door-to-door pickup.** `campus_point` is close to
  where a student lives, so it's never shown to other riders. They see only the meeting
  point and first names.
- **Meeting point = shortest farthest walk.** This is fairer than the shortest average
  walk, which could leave one person walking much further than the others.
- **`FOR UPDATE SKIP LOCKED` when creating a group.** If two matcher runs pick the same
  rider, the second one skips that row instead of waiting or double-booking it, then
  rolls back and regroups.
- **`respond_by` = 2 hours, but at least 1 hour before departure.** Gives riders time
  to answer without the deadline landing after the ride has left.

### Seed script

- **Points spread evenly over a 2 km circle,** using `sqrt(random())` for the radius.
  Without the square root, points bunch up near the centre.
- **Busy times around Thanksgiving break** (Nov 20, 24 and 29), with a 90-minute spread.
  Real demand comes in bursts, and bursts are what make matching possible.
- **Weighted values:** SFO 50% / OAK 35% / SJC 15%; riders mostly 1. Roughly what
  Berkeley travel looks like.
- **Fixed random seed (`--seed 42`).** The same data every run, so a change in match
  rate comes from the code, not from different random data.
- **`fake###@berkeley.edu` emails.** Passes the Berkeley-only check, and `--reset` can
  delete exactly these rows without touching real ones.
- **One transaction.** If any insert fails, nothing is saved, so there's no half-seeded
  database.

## What's next

**Task 9: Make two decisions** and write them in `docs/plan.md`:
- Bag limit per car (e.g. 4 large bags total).
- Which candidates to pick when there are more than seats (closest first is simplest).

**Task 10: Grouping logic** (`src/carpool/grouping.py`). Plain Python, no database.
Takes a request plus its candidates and returns a group or `None`. It checks riders ≤ 4,
bags ≤ the limit, and that the common window (latest start to earliest end) isn't empty.

**Task 11: Unit tests** (`tests/test_grouping.py`). Cases: 2 compatible riders; 5 riders
where only 4 fit; a 3-rider plus a 2-rider request; windows A-B and B-C overlap but A-C
don't; too many bags.

**Task 12: Connect to the database** (`src/carpool/matcher.py`). `match_request(id)`
runs query 1, then grouping, then query 2 (no row → try a smaller group), then query 3
in one transaction.

**Task 13: Concurrency test.** Two connections create groups for overlapping riders at
once; check that no request ends up in two proposed groups.

**Task 14: Simulation** (`scripts/simulate.py`). Reseed, match every request, and print
the match rate, group sizes and average farthest walk. Report coverage separately (see
`docs/known-issues.md` #1).

**Before Task 14, fix:**
- Meeting point coverage (known issue #1).
- Seed dates after Nov 29 (known issue #2).

**Still open in `docs/plan.md`:**
- Backend and frontend frameworks.
- Map provider.
- How confirmed riders contact each other.
- How to avoid proposing the same group again after a decline.
- Hosting with PostGIS.
