"""Generate fake users and open trip requests to test matching without real users.

Run: uv run --env-file .env python scripts/seed.py --reset
"""

import argparse
import math
import random
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from carpool.db import connect

PT = ZoneInfo("America/Los_Angeles")

CAMPUS_LAT, CAMPUS_LNG = 37.8721, -122.2578  # Campanile
MAX_METERS_FROM_CAMPUS = 2000
METERS_PER_DEGREE_LAT = 111_000
METERS_PER_DEGREE_LNG = 88_000  # smaller than latitude at Berkeley's latitude

# Busy travel times around Thanksgiving break, the direction riders travel then,
# and how many requests (weight) cluster around each one
ANCHORS = [
    (datetime(2026, 11, 20, 15, 0, tzinfo=PT), "to_airport", 20),    # Friday weekend trips
    (datetime(2026, 11, 24, 14, 0, tzinfo=PT), "to_airport", 45),    # break starts
    (datetime(2026, 11, 29, 18, 0, tzinfo=PT), "from_airport", 35),  # flying back
]
WINDOW_SPREAD_MINUTES = 90  # standard deviation of window starts around an anchor

FAKE_EMAIL_PATTERN = "fake%@berkeley.edu"  # SQL LIKE pattern matching every seeded user


def random_campus_point() -> tuple[float, float]:
    """Return (lat, lng) spread evenly over a disc around campus."""
    # sqrt keeps points even per area; without it they bunch up near the centre
    meters = MAX_METERS_FROM_CAMPUS * math.sqrt(random.random())
    angle = random.uniform(0, 2 * math.pi)
    lat = CAMPUS_LAT + meters * math.cos(angle) / METERS_PER_DEGREE_LAT
    lng = CAMPUS_LNG + meters * math.sin(angle) / METERS_PER_DEGREE_LNG
    return lat, lng


def random_window() -> tuple[datetime, datetime, str]:
    """Return (start, end, direction) clustered around one of the busy times."""
    anchor, direction, _ = random.choices(ANCHORS, weights=[a[2] for a in ANCHORS])[0]
    start = anchor + timedelta(minutes=random.gauss(0, WINDOW_SPREAD_MINUTES))
    start = start.replace(minute=start.minute // 15 * 15, second=0, microsecond=0)  # round to 15 min
    end = start + timedelta(hours=random.choice([1, 2, 3, 4]))  # schema allows at most 4 hours
    return start, end, direction


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reset", action="store_true", help="delete earlier seed rows first")
    parser.add_argument("--count", type=int, default=200, help="number of fake requests")
    parser.add_argument("--seed", type=int, default=42, help="random seed, for repeatable data")
    args = parser.parse_args()

    random.seed(args.seed)  # same data every run, so simulation results are comparable
    now = datetime.now(PT)

    # One transaction: commits at the end of the block, or rolls back on any error
    with connect() as conn:
        if args.reset:
            # Deleting users cascades to their trip_requests and group_members rows
            conn.execute("DELETE FROM users WHERE email LIKE %s", (FAKE_EMAIL_PATTERN,))
            # ride_groups has no FK to requests, so remove groups left with no members
            conn.execute(
                """DELETE FROM ride_groups g
                   WHERE NOT EXISTS (SELECT 1 FROM group_members gm WHERE gm.group_id = g.id)"""
            )

        for i in range(1, args.count + 1):
            user_id = conn.execute(
                "INSERT INTO users (email, name) VALUES (%s, %s) RETURNING id",
                (f"fake{i:03d}@berkeley.edu", f"Fake Student {i:03d}"),
            ).fetchone()[0]

            lat, lng = random_campus_point()
            start, end, direction = random_window()
            airport = random.choices(["SFO", "OAK", "SJC"], weights=[50, 35, 15])[0]
            riders = random.choices([1, 2, 3], weights=[80, 15, 5])[0]
            bags = random.randint(0, 4)
            # Spread submit times over the past week so created_at order is realistic
            created_at = now - timedelta(minutes=random.uniform(0, 7 * 24 * 60))

            conn.execute(
                """INSERT INTO trip_requests
                     (user_id, airport, direction, departure_window, campus_point,
                      riders, bags, created_at, updated_at)
                   VALUES (%s, %s, %s, tstzrange(%s, %s),
                           ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,  -- lng first
                           %s, %s, %s, %s)""",
                (user_id, airport, direction, start, end, lng, lat,
                 riders, bags, created_at, created_at),
            )

    print(f"Inserted {args.count} fake users and open requests.")


if __name__ == "__main__":
    main()
