# victoriametrics

**Planned (T-646).** smolquery as the metrics store: vmagent scrapes every
smolquery pod's `/metrics` and remote-writes to the VictoriaMetrics edge;
Grafana ships with a Prometheus datasource provisioned at the edge.

Host ports: API 9500, the edge 9528, Grafana 9530.
