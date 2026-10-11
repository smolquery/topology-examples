# federated-read-clusters

**Planned (T-643 spike, then T-644).** One writer cluster seals into a lake
(Postgres metadata, RustFS); two independent read clusters, each with only
the `api,query,web` roles and a tiny catalog of its own, register the
writer's lake as a `kind: ducklake` connection and serve queries against
`writer.<dataset>.<table>`. Read capacity scales by adding clusters.

Host ports: writer API 9300, reader-1 API 9301, reader-2 API 9302.
