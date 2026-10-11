# hyperdx

**Planned (T-645).** ClickStack's HyperDX on smolquery's ClickHouse edge,
per upstream `docs/clickstack.md`: an `otel_logs` table with a
`TIMESTAMP_NS` timestamp, HyperDX and MongoDB with the connection and
source provisioned at first boot, and a seed of sample logs to search.

Host ports: API 9400, HyperDX UI 9408, ClickHouse edge 9423.
