# Task list: automatic ride matching

Check off each task as you finish it (`- [ ]` -> `- [x]`).
Each task says what to do, what to run, why it matters, and when it's done.

## Phase 1: Database

- [ ] **Task 1: Start Postgres + PostGIS in Docker**
  - Open Docker Desktop first, then run:
    ```bash
    docker run --name carpool-db -e POSTGRES_PASSWORD=devpass -e POSTGRES_DB=carpool \
      -p 5432:5432 -d postgis/postgis:16-3.4
    docker ps
    ```
  - Why: the matching rules (window overlap, distance, row locks) run inside Postgres.
  - Done when: `docker ps` shows `carpool-db` as "Up".

- [ ] **Task 2: Install psql and load the schema**
  - Run:
    ```bash
    brew install libpq && brew link --force libpq
    psql postgresql://postgres:devpass@localhost:5432/carpool -f db/schema.sql
    psql postgresql://postgres:devpass@localhost:5432/carpool -f db/example_data.sql
    ```
  - Why: `psql` talks to the database directly. The schema creates the tables; the
    example data adds a few rows to test with.
  - Done when: `\dt` lists your 5 tables plus PostGIS's `spatial_ref_sys`, and
    `SELECT count(*) FROM trip_requests;` returns 4.

- [ ] **Task 3: Run the matching queries by hand**
  - Run query 1 from `db/matching.sql` with `4` in place of `:id`. Expect 0 rows.
  - Write an `INSERT` for a new user and an OAK `from_airport` request near Ava's
    point with an overlapping window. Use `POINT(lng lat)`.
  - Run query 1 again. Your request should appear with `meters_apart`.
  - Run query 2 with `ARRAY[4, <your id>]` in place of `:group_request_ids`.
  - Why: understand what each query returns before calling it from Python.
  - Done when: you can explain what each line of query 1's `JOIN` filters out.

- [ ] **Task 4: Create `.env`**
  - Copy `.env.example` to `.env` and set
    `DATABASE_URL=postgresql://postgres:devpass@localhost:5432/carpool`.
  - Why: keeps the connection string out of code and git.
  - Done when: `git status` doesn't list `.env`.

## Phase 2: Python project

- [ ] **Task 5: Set up the project with uv**
  - Run:
    ```bash
    uv init --app --name carpool
    uv add "psycopg[binary]"
    uv add --dev pytest
    ```
  - Why: `pyproject.toml` records dependencies; `.venv` keeps them local to this project.
    `psycopg` is the Postgres driver, `pytest` runs tests.
  - Done when: `uv run python -c "import psycopg; print(psycopg.__version__)"` prints a version.

- [ ] **Task 6: Write a connection helper (`carpool/db.py`)**
  - A function that reads `DATABASE_URL` from the environment and returns `psycopg.connect(...)`.
  - Run:
    ```bash
    uv run --env-file .env python -c "from carpool.db import connect; print(connect().execute('SELECT postgis_version()').fetchone())"
    ```
  - Why: every script and test connects through one place. `--env-file` loads `.env`.
  - Done when: it prints a PostGIS version.

## Phase 3: Fake data

- [ ] **Task 7: Add more meeting points**
  - Only 2 exist, both downtown. Add 3 to 5 more (e.g. North Gate, Telegraph/Bancroft,
    Clark Kerr). Look up coordinates on a map.
  - Update `db/schema.sql` and `docs/plan.md` together (CLAUDE.md rule).
  - Why: with few meeting points, many riders are more than 1 km from all of them and
    never match. The match rate would measure point placement, not your matcher.

- [ ] **Task 8: Write the seed script (`scripts/seed.py`)**
  - Generate about 200 fake users and requests:
    - Locations: random points within about 2 km of campus.
      At Berkeley, 1° latitude ≈ 111 km, 1° longitude ≈ 88 km.
    - Airports: weighted, e.g. SFO 50%, OAK 35%, SJC 15%.
    - Windows: clustered around busy times (Friday afternoon, start of a break),
      1 to 4 hours long.
    - Riders mostly 1, sometimes 2 or 3. Bags 0 to 4.
    - Emails like `fake001@berkeley.edu` (the CHECK constraint requires @berkeley.edu).
    - A `--reset` flag that deletes old seed rows first.
  - Run: `uv run --env-file .env python scripts/seed.py --reset`
  - Why: no real users yet. This data is how you test and measure matching.
  - Done when: `SELECT airport, count(*) FROM trip_requests GROUP BY airport;` looks
    sensible and there are no insert errors.

## Phase 4: The matcher

- [ ] **Task 9: Make two decisions**
  - Bag limit per car (e.g. 4 large bags total).
  - Which candidates to pick when there are more than seats (closest first is simplest).
  - Write both in `docs/plan.md`.
  - Why: these are product rules the code depends on.

- [ ] **Task 10: Write the grouping logic in plain Python (`carpool/grouping.py`)**
  - A function that takes a request plus its candidates (plain data, no database) and
    returns a proposed group or `None`. It checks:
    - total riders ≤ 4 and total bags ≤ your limit
    - the common window (latest start to earliest end) is not empty
    - a departure time inside the common window (e.g. its start)
  - Why: this is the core of the feature. No database means fast, simple tests.

- [ ] **Task 11: Write unit tests (`tests/test_grouping.py`)**
  - Cases to cover:
    - 2 compatible riders -> group
    - 5 riders -> only 4 get in
    - a 3-rider request plus a 2-rider request -> can't share a car
    - windows A-B and B-C overlap, but A and C don't
    - bags over the limit -> rejected
  - Run: `uv run pytest`
  - Why: proves each rule works and catches later breakage.
  - Done when: all pass, and you've seen each one fail at least once.

- [ ] **Task 12: Connect it to the database (`carpool/matcher.py`)**
  - `match_request(request_id)`:
    1. Run query 1 for candidates.
    2. Call your grouping function.
    3. Run query 2 for the meeting point. No row -> try a smaller group.
    4. Run query 3 in one transaction with `FOR UPDATE SKIP LOCKED`.
       Fewer rows locked than asked for -> roll back.
    5. Skip the group if `respond_by` would already be past (departure under 1 hour away).
  - psycopg uses `%(id)s` where `matching.sql` has `:id`.
  - Why: this step creates groups. The transaction stops one rider landing in two groups.

- [ ] **Task 13: Write a concurrency test**
  - Two connections run group creation for overlapping riders at the same time.
  - Check no request is in two proposed groups:
    ```sql
    SELECT request_id FROM group_members gm JOIN ride_groups g ON g.id = gm.group_id
    WHERE g.status = 'proposed' GROUP BY request_id HAVING count(*) > 1;
    ```
  - Why: the most likely bug in this kind of system, and the hardest to see by hand.
  - Done when: the query returns 0 rows.

## Phase 5: Measure it

- [ ] **Task 14: Simulation script (`scripts/simulate.py`)**
  - Reseed, run `match_request` on every open request in `created_at` order, then print:
    - % of requests placed in a group
    - group size breakdown (2 / 3 / 4)
    - average farthest walk to the meeting point
  - Why: shows whether matching works. Change the meeting points or the 1.5 km radius
    and compare. Use the real number on your resume.

- [ ] **Task 15: Commit your work**
  - Run `git checkout -b matching`, then commit after each phase.
  - Why: small commits let you undo mistakes and show progress.
