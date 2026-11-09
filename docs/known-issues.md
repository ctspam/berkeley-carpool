# Known issues

Problems found so far, why they happen, and how to fix them.
Most important first. Remove an item once it's fixed.

Last updated: 2026-11-09.

## Troubleshooting tree

Start at the symptom. Do the checks in order; the first one that matches is usually the
cause. When you hit a new problem, add a branch here and a section below.

```
Script or test fails
├─ ModuleNotFoundError: No module named 'carpool'
│   ├─ uv warns "VIRTUAL_ENV ... does not match"  → #4: unset VIRTUAL_ENV
│   └─ `ls -lO .venv/lib/python3.13/site-packages/*.pth` shows "hidden" → #3
├─ RuntimeError: DATABASE_URL is not set          → add `--env-file .env` to uv run
├─ psycopg "connection refused" / "could not connect"
│   ├─ `docker ps` fails ("failed to connect to the docker API") → open Docker Desktop
│   ├─ `docker ps -a` shows carpool-db "Exited"
│   │   └─ `docker logs --tail 5 carpool-db` says "bogus data in lock file" → #5
│   └─ container "Up" but still refused → port 5432 used by another Postgres?
│       `lsof -i :5432`
└─ SQL error on insert
    ├─ violates check "users_email_check"   → email isn't @berkeley.edu
    ├─ violates "window_is_bounded"         → window empty, open-ended, or > 4 h
    └─ conflicts with "one_active_request_per_window" → same user, overlapping window

Matching runs but results look wrong
├─ 0 candidates for every request
│   ├─ all windows in the past? `SELECT max(upper(departure_window)) FROM trip_requests;` → #2
│   ├─ all requests not 'open'? `SELECT status, count(*) FROM trip_requests GROUP BY 1;`
│   │   → reseed with --reset
│   └─ points in the ocean / wrong city? lat and lng swapped (ST_MakePoint is lng, lat)
├─ candidates found but no group forms
│   ├─ query 2 returns no row → rider > 1 km from every point → #1
│   └─ grouping rejects → riders > 4 or bags over the limit (Task 9 decision)
├─ low match rate overall → check coverage first (#1), then the matcher
└─ one request in two groups → missing FOR UPDATE SKIP LOCKED or no rollback
    when fewer rows are locked than asked for (Task 12/13)
```

## Watch for in upcoming tasks

Likely causes of bugs that haven't happened yet. Move one into the tree once it does.

| Task | Possible problem | How to tell |
|---|---|---|
| 10 | Window end treated as inclusive. `tstzrange` is `[start, end)`: 2-4pm and 4-6pm don't overlap | Unit test with touching windows |
| 10 | Departure time picked outside one member's window | Assert it's inside every window |
| 10 | Mixing timezone-aware and naive datetimes | Python raises "can't compare offset-naive and offset-aware" |
| 12 | `:id` from `matching.sql` left in Python. psycopg needs `%(id)s` | Syntax error at ":" |
| 12 | Locking fewer rows than asked without rolling back | Concurrency test (Task 13) finds a request in two groups |
| 12 | Group with `respond_by` already past (departure < 1 h away) | `respond_by <= created_at` rows |
| 12 | Same group proposed again after a decline (open decision in plan) | Same set of request ids in a new cancelled group |
| 14 | Example and Task 3 rows counted in the simulation | Filter on `fake%@berkeley.edu` |
| 14 | Different random data between runs | Keep `--seed` fixed when comparing changes |

## 1. About 37% of seeded riders can never be matched

**What:** Only 130 of 205 requests are within 1 km of any meeting point. The meeting
point rule says every group member must be within 1 km of the group's meeting point,
so the other 75 can't join any group.

**Not a bug, and not a lack of users.** There are two kinds of "unmatched":

| Kind | Cause | Gets better with more users? |
|---|---|---|
| Nobody compatible | No one else with the same airport, direction, overlapping window, within 1.5 km | Yes |
| Outside coverage | Rider is more than 1 km from every meeting point | No. Even 10,000 nearby riders can't share a meeting point |

This one is the second kind. It caps the match rate at about 63% before the matcher
runs. That's the problem Task 7 warns about: the match rate would measure where the
points are, not the matcher.

**Fix options:**
- Add meeting points where the uncovered riders are (likely west and north-west).
  Simplest.
- Raise the 1 km walk limit (e.g. 1.5 km). More coverage, longer walks.
- Dynamic meeting point (group centre or a rider's pickup). More complex, and goes
  against the privacy rule about not revealing where riders live.

**For Task 14:** report coverage and match rate separately:
"X% of riders are within 1 km of a meeting point; of those, Y% were matched."

Check coverage:
```sql
SELECT count(*) FILTER (WHERE near) AS covered, count(*) AS total
FROM (SELECT EXISTS (SELECT 1 FROM meeting_points m
                     WHERE ST_DWithin(m.location, r.campus_point, 1000)) AS near
      FROM trip_requests r) t;
```

## 2. Seed data stops working after November 29, 2026

**What:** `scripts/seed.py` puts every window around fixed dates (Nov 20, 24 and 29,
2026). Query 1 in `db/matching.sql` skips windows that have ended
(`upper(departure_window) > now()`). After about Nov 30, every seeded request is in the
past, so the matcher finds 0 candidates and the match rate drops to 0%.

**Fix:** set the busy times relative to today instead of fixed dates, e.g.
"next Friday 3pm", or `now() + 10 days`.

## 3. `ModuleNotFoundError: No module named 'carpool'`

**What:** macOS marks the `.venv` folder and
`.venv/lib/python3.13/site-packages/carpool.pth` as hidden. Python 3.13 ignores hidden
`.pth` files, so it can't find `src/carpool`. A normal `uv run` sets the hidden flag
again, so clearing it once doesn't last. Seen with uv 0.13.0.

**Workaround:**
```bash
chflags nohidden .venv/lib/python3.13/site-packages/*.pth
uv run --no-sync --env-file .env python scripts/seed.py --reset
```

**Fix later:**
- For tests: add this to `pyproject.toml` so pytest finds `src/` either way:
  ```toml
  [tool.pytest.ini_options]
  pythonpath = ["src"]
  ```
- For scripts: find out what sets the flag, or run with `PYTHONPATH=src`.

## 4. Two copies of the project

**What:** There is an old copy at `~/Downloads/berkeley-carpool` and the real one at
`~/Documents/berkeley-carpool`. Your shell's `VIRTUAL_ENV` still points at the
Downloads copy, so uv prints a warning and may use the wrong environment.

**Fix:** Run `unset VIRTUAL_ENV`, and remove any `activate` line for the Downloads
path from `~/.bash_profile` or `~/.zshrc`. When you're sure nothing is only in the
Downloads copy, delete it.

## 5. Postgres won't start after Docker shuts down uncleanly

**What:** If Docker or the Mac shuts down while `carpool-db` is running, Postgres can
leave stale lock files. On the next start it fails with
`FATAL: bogus data in lock file` and the container exits right away. Your data is fine.

**Fix (used on 2026-11-09):**
```bash
# 1. Lock file in the data volume (container must be stopped)
docker run --rm --volumes-from carpool-db postgis/postgis:16-3.4 \
  rm /var/lib/postgresql/data/postmaster.pid
# 2. Socket lock inside the container: overwrite it with a dead PID so Postgres clears it
printf '99999\n' > /tmp/stale.lock
docker cp /tmp/stale.lock carpool-db:/var/run/postgresql/.s.PGSQL.5432.lock
docker start carpool-db
docker logs --tail 3 carpool-db   # expect "ready to accept connections"
```

**Prevent it:** run `docker stop carpool-db` before quitting Docker or shutting down.

## 6. Smaller things

- **The image runs under emulation.** `postgis/postgis:16-3.4` is an x86_64 image on an
  Apple Silicon Mac, so it's slower. Fine for local work.
- **Example rows are still in the database.** `seed.py --reset` deletes only
  `fake%@berkeley.edu` users, so the 5 users from `example_data.sql` and Task 3 stay.
  The simulation will include them unless it filters them out.
- **The database was patched, not reloaded.** The 4 new meeting points were added with
  an `INSERT`, not by reloading `schema.sql`. The ids (1 to 6) match a fresh load, so
  nothing breaks.
- **`docs/tasks.md` checkboxes aren't ticked,** even for finished tasks.
- **2 commits are on `matching` but not pushed** (`git push`).
