# hyperdx

[ClickStack](https://clickhouse.com/docs/clickstack/getting-started/oss)'s
HyperDX, a log search UI built for ClickHouse, reading a smolquery table
through the ClickHouse HTTP edge. HyperDX never learns it is not talking to
ClickHouse: the edge answers `system.tables`, `DESCRIBE`, the parameterised
search SQL, `hasToken`, `groupUniqArray`, and the `JSON` and
`JSONCompactEachRowWithNamesAndTypes` formats it asks for. Upstream's recipe
is [`docs/clickstack.md`](https://github.com/smolquery/smolquery/blob/main/docs/clickstack.md).

```
  browser :9408 ─▶ HyperDX ──▶ MongoDB (its own state)
                      │  ClickHouse HTTP, X-ClickHouse-Key
                      ▼
            smolquery-0  :8123 clickhouse edge   :4000 api
            every role, DuckLake catalog on Postgres
                      ▲
            seed Job: default.otel_logs, 120 log lines
```

## Run it

```sh
mise run kind-up
mise run up hyperdx          # waits for the seed Job too
mise run test hyperdx
open http://localhost:9408   # HyperDX; make an account, the Logs source is already there
```

| what | where | credential |
|---|---|---|
| HyperDX | `http://localhost:9408` | create a team on first visit |
| HTTP API | `http://localhost:9400` | `Bearer kind-only-api-key` |
| ClickHouse edge | `http://localhost:9423` | `X-ClickHouse-Key: kind-only-api-key` |

HyperDX's connection (`smolquery`, `http://smolquery:8123`) and its `Logs`
source on `default.otel_logs` are provisioned from `DEFAULT_CONNECTIONS` and
`DEFAULT_SOURCES` on the first boot. To change either, delete the `mongo`
pod and let HyperDX boot again.

## What the suite proves

The seed Job writes the 120 rows upstream's HyperDX search fixture was
recorded against, and the suite replays that fixture, verbatim from
HyperDX's source, against the edge:

- HyperDX is healthy and its connection test (`SELECT 1`) answers.
- Every statement its Search page sends answers 200: settings, version,
  `DESCRIBE`, `system.tables`, skip indices, the cloud probe, the results
  table, the histogram, a term search, field filters, map keys and field
  values.
- The metadata it reads: `Timestamp` is `DateTime64(9)`, `LogAttributes` is
  `Map(String, String)`, the sorting key is `ServiceName, Timestamp`.
- The results table answers the rows newest first; the histogram counts 15
  errors and 45 infos per minute; a term search and a `LogAttributes` key
  filter both find exactly the 30 error lines; the filters sidebar lists
  `http.status`, the two services and the two severities.

Driving the HyperDX browser UI is out of scope here. Its pod log and
smolquery's are the place to look: the edge runs with
`SMOLQUERY_CLICKHOUSE_UNANSWERED_LOG=verbatim`, so every statement HyperDX
sends that smolquery could not answer is logged with its literals.

## Why a Postgres catalog

HyperDX sends its metadata queries in parallel. On a node whose DuckLake
catalog is SQLite, several job engines attaching it at once can hit
`database is locked`, and the node then stays locked until it restarts. A
Postgres catalog does not have that problem, so this is one pod with every
role, but on Postgres.
