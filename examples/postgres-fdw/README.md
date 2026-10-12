# postgres-fdw

OLTP and OLAP joined from Postgres, and back the other way. A plain Postgres
holding a `users` table attaches smolquery's Postgres wire listener as a
foreign server, imports a smolquery dataset as foreign tables, and joins
them in ordinary SQL. In the other direction, smolquery registers that
Postgres as a federated connection and joins its rows from the OLAP side.

```
       postgres_fdw: IMPORT FOREIGN SCHEMA, scans and aggregates pushed down
  ┌──────────────────┐  ───────────────────────────────▶  ┌──────────────────┐
  │ oltp-postgres    │                                     │ smolquery-0      │
  │  public.users    │  ◀───────────────────────────────   │  <dataset>.events│
  │  :9606           │   /v1/connections "oltp": a read-   │  pg :9605        │
  └──────────────────┘   only attach, oltp.public.users    │  api :9600       │
                                                           └──────────────────┘
```

## Run it

```sh
mise run kind-up
mise run up postgres-fdw
mise run test postgres-fdw
```

| what | where | credential |
|---|---|---|
| smolquery HTTP API | `http://localhost:9600` | `Bearer kind-only-api-key` |
| smolquery Postgres wire | `psql "host=localhost port=9605 user=smolquery dbname=smolquery password=kind-only-api-key"` | the API key |
| the OLTP Postgres | `psql "host=localhost port=9606 user=app dbname=app password=kind-only-oltp-password"` | `app` / `kind-only-oltp-password` |

The OLTP database boots with `postgres_fdw`, the foreign server `smol`
(host `smolquery`, port 5432, the API key as the password) and the user
mapping already created, from `oltp-init.sql`. So a session starts at the
import:

```sql
-- in psql against the OLTP database, after creating a dataset in smolquery
CREATE SCHEMA analytics;
IMPORT FOREIGN SCHEMA analytics FROM SERVER smol INTO analytics;
\det+ analytics.*

SELECT u.plan, count(*), sum(e.amount)
  FROM public.users u JOIN analytics.events e ON e.user_id = u.id
 GROUP BY u.plan;

EXPLAIN VERBOSE SELECT user_id, count(*) FROM analytics.events GROUP BY user_id;
-- Foreign Scan ... Remote SQL: SELECT user_id, count(*) FROM ... GROUP BY 1
```

And from the smolquery side:

```sh
auth='authorization: Bearer kind-only-api-key'
json='content-type: application/json'
curl -H "$auth" -H "$json" -d '{"name":"oltp","host":"oltp-postgres","database":"app",
  "username":"app","password":"kind-only-oltp-password","sslmode":"disable"}' \
  http://localhost:9600/v1/connections
curl -H "$auth" -H "$json" -d '{"query":"SELECT u.plan, count(*) AS n FROM analytics.events e JOIN oltp.public.users u ON u.id = e.user_id GROUP BY u.plan"}' \
  http://localhost:9600/v1/queries
```

## What the suite proves

From the Postgres side:

- `IMPORT FOREIGN SCHEMA` builds the foreign table with the right types
  (`INT64` as `bigint`, `NUMERIC(38,2)` as `numeric`).
- An aggregate over the foreign table is pushed down: the rows are right,
  and `EXPLAIN VERBOSE` shows the `count(*)` and `GROUP BY` in the Foreign
  Scan's Remote SQL.
- A join between the OLTP `users` table and the foreign `events` answers
  the right count and sum per plan.
- A `REPEATABLE READ` block pins its read: rows inserted into smolquery
  mid-block do not change the block's count, and a fresh count after
  `COMMIT` sees them.

From the smolquery side:

- The registered connection is listed and its `test` route reaches the
  database.
- A federated join over `oltp.public.users` answers the same per-plan
  figures.
- The attachment is read-only: an `UPDATE` through it is refused, and the
  OLTP rows are untouched.

## Limits worth knowing

- A foreign scan materializes at `DECLARE` and is capped at
  `result_max_rows` (10,000): push aggregation down or raise
  `SMOLQUERY_MAX_RESULT_ROWS`. `postgres_fdw` deparses to two-part names,
  so it cannot name a smolquery federated connection (`oltp.public.users`)
  from the Postgres side; `dblink` can, by passing SQL through as text.
- The wire listener runs without TLS here, and the foreign server uses
  `sslmode 'disable'`. Beyond one node, give the listener a certificate
  (`SMOLQUERY_PG_TLS_CERT`/`_KEY`) and use `verify-full`.
- The smolquery connection uses `sslmode: "disable"` toward the OLTP
  Postgres for the same kind-only reason; the API defaults to `require`.
