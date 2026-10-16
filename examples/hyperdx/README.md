# hyperdx

[ClickStack](https://clickhouse.com/docs/clickstack/getting-started/oss)'s
HyperDX, the logs, traces and metrics UI built for ClickHouse, reading
smolquery tables through the ClickHouse HTTP edge. HyperDX never learns it
is not talking to ClickHouse: the edge answers `system.tables`, `DESCRIBE`,
the parameterised search SQL, `hasToken`, `groupUniqArray`, the trace
screens' `quantiles(0.5, 0.95, 0.99)(x)`, the metrics charts' window
functions and array arithmetic, and the `JSON` and
`JSONCompactEachRowWithNamesAndTypes` formats it asks for. Upstream's recipe
is [`docs/clickstack.md`](https://github.com/smolquery/smolquery/blob/main/docs/clickstack.md).

```
  browser :9408 ─▶ HyperDX 2.41.0 ──▶ MongoDB (its own state)
                      │  ClickHouse HTTP, X-ClickHouse-Key
                      │  sources: Logs, Traces, Metrics
                      ▼
            smolquery-0  :8123 clickhouse edge   :4000 api
            every role, DuckLake catalog on Postgres
                      ▲
            seed Job: default.otel_logs            120 log lines
                      default.otel_traces          60 traces, 3 spans each
                      default.otel_metrics_gauge   CPU and memory
                      default.otel_metrics_sum     request and queue counters
                      default.otel_metrics_histogram  request and query durations
```

## Run it

```sh
mise run kind-up
mise run up hyperdx          # waits for the seed Job too
mise run test hyperdx
open http://localhost:9408   # HyperDX; make an account, the three sources are there
```

| what | where | credential |
|---|---|---|
| HyperDX | `http://localhost:9408` | create a team on first visit |
| HTTP API | `http://localhost:9400` | `Bearer kind-only-api-key` |
| ClickHouse edge | `http://localhost:9423` | `X-ClickHouse-Key: kind-only-api-key` |

The seed rows sit in fixed windows, the ones upstream's fixtures were
recorded against, so set HyperDX's time range by hand:

| screen | time range (UTC) | what to look at |
|---|---|---|
| Search, Logs | 2026-09-19 10:11 to 10:13 | the histogram by severity, a search for `payment`, the `LogAttributes.http.status` filter |
| Search, Traces | 2026-10-15 11:00 to 12:00 | `checkout`, `StatusCode:Error`, a row's waterfall (web -> api -> worker), the service map |
| Chart Explorer, Metrics | 2026-10-15 11:00 to 12:00 | `system.cpu.utilization` by `ServiceName`, the rate of `http.server.request.count`, p95 of `http.server.duration` |

HyperDX's connection (`smolquery`, `http://smolquery:8123`) and its three
sources are provisioned from `DEFAULT_CONNECTIONS` and `DEFAULT_SOURCES` on
the first boot, named for each other as HyperDX's stock compose file does,
so a trace shows its logs and a log its trace. To change any of it, delete
the `mongo` pod and let HyperDX boot again.

## What the suite proves

The seed Job writes the rows upstream's fixtures were recorded against, and
the suite replays those fixtures, verbatim from HyperDX's source, against
the edge:

- HyperDX is healthy and its connection test (`SELECT 1`) answers.
- **Logs.** Every statement the Search page sends answers 200. The
  metadata it reads: `Timestamp` is `DateTime64(9)`, `LogAttributes` is
  `Map(String, String)`, the sorting key is `ServiceName, Timestamp`. The
  results table answers the rows newest first; the histogram counts 15
  errors and 45 infos per minute; a term search and a `LogAttributes` key
  filter both find exactly the 30 error lines; the filters sidebar lists
  `http.status`, the two services and the two severities.
- **Traces.** Statements shaped as HyperDX 2.41.0 composes them (upstream
  keeps no trace fixture yet): `Duration` is `Int64` and the sorting key is
  `ServiceName, SpanName, Timestamp`; a term, a phrase, a field, a map key
  and a duration range each find the spans they name; the histogram by
  `StatusCode` and the p95 latency by service per five minutes answer; one
  trace's waterfall comes back parented web -> api -> worker; the service
  map's `quantiles(0.5, 0.95, 0.99)(Duration)` answers three percentiles
  per service as one `Array(Nullable(Float64))`.
- **Metrics.** Every one of the 24 statements upstream's metrics fixture
  holds answers 200, with the `meta` types HyperDX's chart code classifies
  (the time bucket as `DateTime64(6)`, values as `Float64` or `Int128`):
  the catalog per table, name search, a metric's unit, attributes and
  values; gauge charts averaged, maxed, filtered, grouped by an attribute
  and as a delta; a cumulative counter's rate, increase and last value and
  a delta counter; histogram p95 and p50 from bucket deltas and counts;
  and multi-series charts, a ratio, a formula and a histogram beside a
  gauge. The sums the fixture's rows imply hold exactly.

Driving the HyperDX browser UI is out of scope here. Its pod log and
smolquery's are the place to look: the edge runs with
`SMOLQUERY_CLICKHOUSE_UNANSWERED_LOG=verbatim`, so every statement HyperDX
sends that smolquery could not answer is logged with its literals.

## Limits worth knowing

- **Rows reach smolquery through its own ingest, not ClickStack's
  collector.** The OpenTelemetry collector ClickStack ships speaks
  ClickHouse's `Native` format and runs ClickHouse DDL at start, which
  smolquery does not answer (upstream T-497, T-498, T-499). The seed Job
  is NDJSON over the API; a shipper that writes NDJSON (Vector's `http`
  sink, for one) is the shape for live data. smolquery itself exports its
  spans over OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (v0.24.0), so
  its own traces can be shipped back into `otel_traces` that way: T-669.
- **Not drawn yet:** span events and links (`Events.*` and `Links.*` are
  `Array` columns with dotted names), exponential histograms (their
  quantile SQL names an alias before defining it) and sessions. Upstream
  T-501 tracks them. The `summary` metric type has no chart in HyperDX.
- The metric tables carry every column of the exporter's but
  `Exemplars.*`, which HyperDX never reads.

## Why a Postgres catalog

HyperDX sends its metadata queries in parallel. On a node whose DuckLake
catalog is SQLite, several job engines attaching it at once can hit
`database is locked`, and the node then stays locked until it restarts. A
Postgres catalog does not have that problem, so this is one pod with every
role, but on Postgres.
