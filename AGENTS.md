topology-examples is a set of runnable smolquery deployment shapes: one
kustomization, one README and one ExUnit suite per example, all deployed
into a single local kind cluster. [`README.md`](README.md) is the overview;
the design is plan `PL-75` in the project tracker.

## Project guidelines

- Plans and tasks live in the **smolquery-pm tracker** (a smolsqls database
  shared with upstream smolquery). This repo is project `topology-examples`
  (`P-4`). Use the `smolquery-pm` skill (`./skills/install.sh` links it);
  don't create local plan markdown. Cite keys (`T-641`, `PL-75`) in commits
  and PR bodies, never a bare `#<id>`.
- `mix precommit` before you are done with a change (compile with
  warnings-as-errors, format, `credo --strict`, the harness's own tests).
  `mix ci` is the non-mutating gate CI runs.
- One pinned upstream version for the whole repo (`v0.21.0` today): the
  image tag in every example's `kustomization.yaml` and the `ref=` of every
  remote base. Bumping is one PR that moves all of them.
- Upstream manifests are referenced by git ref
  (`https://github.com/chasers/smolquery//deploy/base?ref=...`), never
  copied into this repo. An example carries only what upstream does not
  ship (a dedicated query tier, a reader deployment, HyperDX, vmagent,
  Grafana, an OLTP Postgres). The dependencies every fleet needs live in
  `components/` (Postgres, and RustFS as the object store; never MinIO).
- Every example deploys into a namespace named after it, exposes host ports
  from its own block in `kind/cluster.yaml`, and uses the API key
  `kind-only-api-key`. `Topology.Example` holds the same port table, and
  `test/topology/example_test.exs` checks the two agree.
- Use `Req` for HTTP and `Postgrex` for anything Postgres-shaped (the wire
  listener included). No other HTTP clients.

## An example's suite

- `test/examples/<name>_test.exs`, `@moduletag :<name>` with dashes as
  underscores, excluded in `test/test_helper.exs`, `async: false`.
- `setup_all` starts with `Topology.Example.require_up!/1`, then takes a
  dataset of its own (`Topology.Api.unique_name/1`): catalogs and PVCs
  outlive a redeploy, and a fixed name accumulates rows across runs.
- A destructive test (kill, restart, scale) restores what it disturbed in
  `on_exit`, so ExUnit's shuffling cannot make one test depend on another.
- Each test asserts the property the shape exists to show, and says so in
  its name. A test that would pass against any topology belongs in
  `single-node`, not duplicated everywhere.

## Elixir guidelines

- No inline or explanatory comments in `.ex`/`.exs`; documentation lives in
  `@moduledoc`/`@doc`/`@spec`. YAML and shell may carry comments that say
  why a setting is what it is.
- Tagged tuples for returns (`{:ok, _}` / `{:error, _}`); `with`/`case`
  threading. Never `String.to_atom/1` on unbounded input.
- Every public function in `lib/topology/` has a `@spec`.
