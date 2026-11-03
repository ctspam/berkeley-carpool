# Berkeley Airport Ride Matching

Matches UC Berkeley students into shared rides to and from SFO, OAK, and SJC.
A student submits one request with a time window and a pickup point near campus.
The backend groups riders whose windows overlap and who are within walking distance
of a shared meeting point.

Built with PostgreSQL and PostGIS. See docs/plan.md for the full design.

## Local database setup

Requires PostgreSQL 14+ with PostGIS.

```bash
# Create the database, then load the schema and sample rows
createdb carpool
psql -d carpool -f db/schema.sql
psql -d carpool -f db/example_data.sql
```
