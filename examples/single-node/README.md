# single-node

The whole of smolquery in one pod: `SMOLQUERY_ROLES=all`, the DuckLake
catalog in SQLite, the sealed tier on the pod's volume, and every protocol
edge open. The simplest shape there is, and the one to start from.

```
                    ┌──────────────────────────────────┐
  HTTP API  :9100 ─▶│ smolquery-0                      │
  web UI    :9102 ─▶│  api · ingest · buffer · storage │
  psql      :9105 ─▶│  query · web · pg · clickhouse   │
  ClickHouse:9123 ─▶│  victoriametrics                 │
  Prom/VM   :9128 ─▶│  /data: hot tier, sealed, catalog│
                    └──────────────────────────────────┘
```

## Run it

```sh
mise run kind-up
mise run up single-node
mise run test single-node
```

| what | where | credential |
|---|---|---|
| HTTP API | `http://localhost:9100` | `Bearer kind-only-api-key` |
| web UI | `http://localhost:9102` | `smolquery` / `kind-only-web-password` |
| Postgres wire | `psql "host=localhost port=9105 user=smolquery dbname=smolquery password=kind-only-api-key"` | the API key |
| ClickHouse HTTP | `http://localhost:9123` | `X-ClickHouse-Key: kind-only-api-key` |
| VictoriaMetrics | `http://localhost:9128` | `Bearer kind-only-api-key` |

## What the suite proves

- The API round trip: a dataset, a table, 200 NDJSON rows, and a query that
  counts 200.
- The Postgres wire listener reads the same rows through Postgrex.
- The ClickHouse edge answers HyperDX's connection test, and the
  VictoriaMetrics edge answers Grafana's `buildinfo`.
- Rows acked before a pod restart are all there after it: durable and
  queryable are the same event, and `/data` is where that lives.

## What this shape does not give you

One pod is one failure domain and one CPU budget. The hot tier, sealing,
and every query share it. When ingest and query need separate capacity,
see `split-compute`; when the catalog needs to outlive a single disk, that
example's Postgres catalog and object store are the move.
