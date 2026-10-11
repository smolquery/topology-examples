# victoriametrics

smolquery as the metrics store. vmagent scrapes every smolquery pod's
`/metrics` and remote-writes the samples to smolquery's own VictoriaMetrics
edge, where each sample lands as a row of `metrics.samples`; Grafana reads
them back in MetricsQL through a provisioned Prometheus datasource pointed
at the same edge. Nothing else runs: no VictoriaMetrics, no Prometheus.

```
  vmagent ──scrape /metrics (4003)──▶ smolquery-0 ◀──remote write (8428)── vmagent
                                      │ all roles, catalog on Postgres
  Grafana ──MetricsQL (8428)─────────▶│ metrics.samples: name, series, labels, ts, value
  :9530                               └── /data
```

## Run it

```sh
mise run kind-up
mise run up victoriametrics
mise run test victoriametrics
```

| what | where | credential |
|---|---|---|
| HTTP API | `http://localhost:9500` | `Bearer kind-only-api-key` |
| VictoriaMetrics edge | `http://localhost:9528` | `Bearer kind-only-api-key`, or basic auth with it as the password |
| Grafana | `http://localhost:9530` | `admin` / `kind-only-grafana-password` |

Grafana opens with a datasource named `smolquery` and a dashboard,
"smolquery as the metrics store", with scrapes per second by job and
remote-written samples per second by result. Try the edge directly:

```sh
curl -sS -H 'authorization: Bearer kind-only-api-key' \
  'http://localhost:9528/api/v1/query?query=sum+by+(job)+(rate(vm_promscrape_scrapes_total[1m]))'
```

## What is in the example

- `smolquery.yaml`: one pod, every role, with the edge and the `/metrics`
  listener bound beyond loopback. The internal secret is fixed in the
  kustomization because vmagent presents it when scraping. The DuckLake
  catalog is on Postgres (`components/postgres`, through `SMOLQUERY_CATALOG`
  so nothing else about the node changes): vmagent's writes, Grafana's
  checks and a dashboard's panels run query jobs at once, and on a SQLite
  catalog those lock each other out until the node restarts (upstream
  `docs/victoriametrics.md`, T-574). The first run of this example hit
  exactly that.
- `seed-job.yaml`: creates `metrics.samples` with the edge's schema and
  clustering, and a 7-day retention, before the first write, so a dashboard
  never finds the table missing.
- `vmagent.yaml`: Kubernetes endpoint discovery over a ClusterRole, a 5 s
  scrape of every `metrics`-named port in the namespace plus vmagent
  itself, one remote-write URL with the API key as the bearer token.
- `grafana.yaml`: the datasource and dashboard, provisioned from
  ConfigMaps.

## What the suite proves

- Scraped samples land: `metrics.samples` fills, and `up` answers `1` for
  the scrape targets.
- `query_range` over `rate(vm_promscrape_scrapes_total[1m])` answers a
  series of points, and the label routes answer.
- Grafana's datasource health check passes through Grafana's API, so the
  edge answers what the Prometheus datasource asks.
- A remote-write block sent twice is written once: the block's SHA-256 is
  its batch id, so a retry after a lost answer cannot double-count.

## What to know

- The edge drops `NaN`, clamps `±Inf`, and stores neither native histograms
  nor exemplars. Everything else vmagent sends is a row.
- The label routes scan the time range they are asked for; keep Grafana's
  label browser to a short range on a large table.
- A query past one of the edge's ceilings (series, samples, points) is a
  422 that names the variable. See upstream `docs/victoriametrics.md`.
