# federated-read-clusters

One writer, many readers, one lake. The writer is the standard smolquery
fleet sealing into a DuckLake whose metadata is Postgres and whose files
are in RustFS. Each reader is an independent smolquery with only the
`api`, `query` and `web` roles, which registers the writer's lake as a
federated DuckLake connection and serves queries against
`writer.<dataset>.<table>`. Read capacity scales by adding readers;
nothing about the writer changes when one comes or goes.

```
  inserts :9300 ─▶ ┌─ writer ──────────────────────────────┐
                   │ smolquery-api · buffer×2 · storage×1  │
                   │   seals ──▶ RustFS  (files)           │
                   │   commits ─▶ Postgres (DuckLake meta)  │
                   └──────────────┬──────────┬─────────────┘
                                  │ ATTACH   │ read-only, through the
                                  │          │ reader's own S3 secret
  queries :9301 ─▶ ┌─ reader-1 ───┴──┐  ┌────┴─ reader-2 ─┐ ◀─ :9302
                   │ api·query·web   │  │ api·query·web   │
                   │ catalog: pg db  │  │ catalog: pg db  │
                   └─────────────────┘  └─────────────────┘
```

## Why a reader names the writer's data path

A reader registers the lake with the writer's own data path,
`/data/ducklake`: the ducklake extension refuses an `ATTACH` whose
`DATA_PATH` differs from the one the catalog stores, and smolquery's attach
never overrides it, so a wrong path fails loudly instead of reading
somewhere else. That path is local to the writer, and the lake's files are
not under it: the writer registers every sealed file by its absolute
`s3://` location, so a reader needs the writer's bucket (`SMOLQUERY_S3_*`)
and nothing at that path. A release allows a local `data_path` only under
`SMOLQUERY_FEDERATION_LOCAL_ROOTS` (smolquery v0.23.0, upstream T-650), so
the reader secret sets it to `/data/ducklake` exactly: `/` is refused.

## Run it

```sh
mise run kind-up
mise run up federated-read-clusters
mise run test federated-read-clusters
```

| what | where | credential |
|---|---|---|
| writer API | `http://localhost:9300` | `Bearer kind-only-api-key` |
| reader-1 API | `http://localhost:9301` | `Bearer kind-only-api-key` |
| reader-2 API | `http://localhost:9302` | `Bearer kind-only-api-key` |

Registering the lake on a reader, by hand:

```sh
curl -H 'authorization: Bearer kind-only-api-key' -H 'content-type: application/json' \
  -d '{"name": "writer", "kind": "ducklake", "host": "postgres", "port": 5432,
       "database": "smolquery", "username": "postgres", "password": "postgres",
       "sslmode": "disable", "data_path": "/data/ducklake"}' \
  http://localhost:9301/v1/connections
curl -H 'authorization: Bearer kind-only-api-key' -H 'content-type: application/json' \
  -d '{"query": "SELECT count(*) FROM writer.<dataset>.events"}' \
  http://localhost:9301/v1/queries
```

## What the suite proves

- Each reader registers the writer's lake at the writer's own data path,
  and the connection test reads a row through it with the reader's own S3
  credential (smolquery v0.24.0, upstream T-659).
- Rows inserted at the writer are, once sealed, read from both readers as
  `writer.<dataset>.<table>`.
- A reader joins lake rows with rows of its own in one query.
- Deleting a reader's pod changes nothing for the writer or the other
  reader.

## What a reader sees, and when

A reader attaches the lake's catalog: it reads the files the catalog
lists, which is the sealed tier only. The writer's hot tier, the rows
acked but not yet sealed, is invisible to a reader until the next seal,
so a reader's view lags the writer by the seal age (`SMOLQUERY_SEAL_MAX_AGE_MS`,
15 s in this example, 60 s by default) on a quiet table and by less on a
busy one. The writer's own queries have no such lag: they union the hot
tier with the catalog snapshot. Put latency-sensitive reads on the writer
and everything else on readers.

## Limits worth knowing

- A reader's own catalog is a database of its own on the shared Postgres
  (`reader_1`, `reader_2`, created by `postgres-init.yaml` on the component's
  first boot), because SQLite locks when the connection probe's engine and a
  query job's history write land together, and the API then answers 500.
  The database holds one row, the connection; a reader has no data of its
  own.

## The trust boundary

A registered lake's catalog decides which files a reader reads, and the
reader reads them wherever the catalog says they are: nothing in the
query engine's lockdown confines an attached lake. Register only a lake
whose catalog you trust as you trust the reader itself. Here the readers
are given the writer's Postgres credential outright; a real deployment
gives them a read-only role on the metadata database and an S3 credential
that can only read the bucket.
