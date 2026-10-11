# split-compute

Separate compute for every service. The ingest front door, the query
tier, the buffer fleet and the storage sealers are each their own
StatefulSet, so each scales on its own and a busy stage cannot starve
another. Postgres holds the DuckLake catalog and node discovery; RustFS
holds the sealed tier. This is the shape of the Supabase sandbox
deployment (supabase/o11y-team-tools PR 119) without the AWS half.

```
  writes :9200 ─▶ smolquery-api ×1   (api, ingest)        stateless
                      │ forward
                      ▼
                  smolquery-buffer ×3 (buffer)             PVC each: the
                      │ seal signal                        acked, unsealed tail
                      ▼
                  smolquery-storage ×2 (storage)           stateless: seals to
                      │                                    RustFS, commits to
                      ▼                                    the Postgres catalog
  queries :9201 ─▶ smolquery-query ×2 (api, query, web, pg) stateless: reads the
  web UI  :9202                                            catalog, RustFS and
  psql    :9205                                            every buffer's tail
```

## Run it

```sh
mise run kind-up
mise run up split-compute
mise run test split-compute
```

| what | where | credential |
|---|---|---|
| writes (HTTP API) | `http://localhost:9200` | `Bearer kind-only-api-key` |
| queries (HTTP API) | `http://localhost:9201` | `Bearer kind-only-api-key` |
| web UI | `http://localhost:9202` | `smolquery` / `kind-only-web-password` |
| Postgres wire | `psql "host=localhost port=9205 user=smolquery dbname=smolquery password=kind-only-api-key"` | the API key |

Upstream's `deploy/base` is referenced at the pinned release, not copied:
this directory holds only what upstream does not ship. The query tier is
`statefulset-query.yaml`; `patch-ingest-roles.yaml` takes `query` and `web`
off the api pod; `patch-seal-age.yaml` makes a quiet table seal after 15 s
so the suite does not wait a minute. `probe.yaml` is a curl pod the suite
uses to list the bucket; it is not part of the topology.

## What the suite proves

- **Roles are strictly local.** The ingest tier answers a query with
  `503 the query service is not available here`, and the query tier
  answers an insert with `503 the write path is not available here`.
  Clients are pointed at the tier that can answer them; nothing forwards.
- **A query fans out.** Two tables that the ring places on two different
  buffer nodes answer in one query, every row counted once.
- **Sealing lands in RustFS through the Postgres catalog.** After the seal,
  the job's statistics show a sealed file, the bucket lists an object under
  the dataset's prefix, `ducklake_data_file` names an `s3://` path, and the
  query reads the rows back from the object store.
- **The query tier is stateless.** A query pod is force-deleted and queries
  keep answering while the StatefulSet replaces it.
- **A buffer owner dying never shortens an answer.** With the owner of a
  table killed, every query during the outage answers either the complete
  count from the replica or `503`, never a short count (upstream T-94),
  and the fleet reads every row again once the pod is back.

## What this shape does not give you

Query capacity is still shared with the HTTP edge that coordinates each
job, and every reader must reach every buffer node. When read capacity
should grow without touching the writer at all, see
`federated-read-clusters`.
