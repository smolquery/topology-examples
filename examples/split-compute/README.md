# split-compute

**Planned (T-642).** Separate compute for each service: an `api,ingest`
front door, a dedicated query tier (`api,query,web,pg`), the buffer
StatefulSet with the only PVCs, stateless storage sealers, a Postgres
catalog and RustFS as the object store. The shape of the Supabase sandbox deployment
(supabase/o11y-team-tools PR 119), without the AWS half.

Host ports: ingest-tier API 9200, query-tier API 9201, web UI 9202,
Postgres wire 9205.
