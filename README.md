# topology-examples

[![Examples](https://github.com/smolquery/topology-examples/actions/workflows/examples.yml/badge.svg)](https://github.com/smolquery/topology-examples/actions/workflows/examples.yml)

Runnable [smolquery](https://github.com/chasers/smolquery) deployment
topologies. Each one is a kustomization you can apply to a local
[kind](https://kind.sigs.k8s.io) cluster in one command, a README that says
what the shape is for, and an ExUnit suite that proves the property the
shape exists to show.

smolquery is one release with nine roles (`api`, `ingest`, `buffer`,
`storage`, `query`, `web`, `pg`, `clickhouse`, `victoriametrics`), a
DuckLake catalog, and four protocol edges. That is a lot of shapes. These
are the ones worth knowing, side by side.

| example | the shape | status |
|---|---|---|
| [`single-node`](examples/single-node) | Everything in one pod: every role, every edge, one volume. | green in CI (T-641) |
| [`split-compute`](examples/split-compute) | Separate compute for ingest, buffer, query and storage; Postgres catalog; RustFS object store. The Supabase sandbox shape. | green in CI (T-642) |
| [`federated-read-clusters`](examples/federated-read-clusters) | One writer seals into a lake; independent read clusters attach it as a federated DuckLake connection. | green in CI; the three lake-attach tests skip until upstream T-650 ships (T-644) |
| [`hyperdx`](examples/hyperdx) | HyperDX (ClickStack) reading logs through the ClickHouse edge. | green in CI (T-645) |
| [`victoriametrics`](examples/victoriametrics) | smolquery as the metrics store behind vmagent and Grafana. | green in CI (T-646) |
| [`postgres-fdw`](examples/postgres-fdw) | OLTP and OLAP joined from Postgres over `postgres_fdw`, and back the other way. | green in CI (T-647) |

## Run one

You need Docker and [mise](https://mise.jdx.dev). mise installs the rest:
the Erlang/Elixir toolchain upstream pins, kind, and kubectl.

```sh
mise install
mise run setup                # hex, rebar, deps
mise run kind-up              # one kind cluster for every example
mise run up single-node       # apply the example, wait for it
mise run test single-node     # its ExUnit suite
mise run down single-node     # delete its namespace; the cluster stays
mise run kind-down            # delete the cluster
```

Each example deploys into a namespace named after it, so several can be up
at once. Every example's host ports are declared in `kind/cluster.yaml`
(one block per example: single-node on 91xx, split-compute on 92xx, and so
on) and listed in its README. The API key everywhere is
`kind-only-api-key`; the web UI is `smolquery` / `kind-only-web-password`.

`kubectl` in this repo is pinned to the `kind-topology-examples` context
through the repo-scoped kubeconfig `scripts/kind-up.sh` writes to `.kube/`,
and the suites pin it the same way, so nothing here can reach another
cluster by accident.

## How the tests work

Every suite is ExUnit, tagged with its example's name
(`@moduletag :single_node`) and excluded by default: `mix test` alone runs
only the harness's own checks. `mix test --only single_node` runs one suite
against the example already deployed, and fails fast, naming the command to
run, when it is not. The shared moves live in `lib/topology/`:

- `Topology.Kube`: kubectl pinned to the cluster and a namespace; `exec`,
  the release's `rpc`, kill, restart, rollout waits.
- `Topology.Api`: the HTTP API: datasets, tables, NDJSON inserts with an
  `insertId` and retries, queries.
- `Topology.Example`: each example's namespace, host ports and credentials.
- `Topology.Eventually`: polling for things that converge on their own time.
- `Topology.ObjectStore`: what the sealed tier wrote, listed through the S3
  API from inside the cluster.

## Upstream is pinned, not vendored

Examples that use the standard fleet reference upstream's
`deploy/base` by git ref, and every example's image is
`ghcr.io/chasers/smolquery` at one tag (`v0.21.0`). Moving the repo to a
new release is one change.

## Layout

```
examples/<name>/      # kustomization, manifests, README per example
components/           # the shared dependencies: RustFS, Postgres
kind/cluster.yaml     # the one kind cluster and every example's host ports
scripts/              # kind-up, example-up/down/test (what mise tasks run)
lib/topology/         # the shared test harness
test/examples/        # one suite per example, tagged and opt-in
test/topology/        # the harness's own checks
skills/               # Claude Code skills for the project tracker
```

## Planning

Plans and tasks live in the same tracker upstream smolquery uses, a
smolsqls database: this repo is project `P-4`, its design doc is plan
`PL-75`, and the examples above cite their task keys. See
[`skills/README.md`](skills/README.md) for the tooling, and
[`AGENTS.md`](AGENTS.md) for conventions. Reference tracker items by their
display key (`T-641`), never a bare `#<id>`.

## License

[Apache License 2.0](LICENSE).
