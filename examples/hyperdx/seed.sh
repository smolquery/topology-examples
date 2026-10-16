#!/bin/sh
# Seeds the tables HyperDX's three stock sources read, through the API:
#
#   default.otel_logs               120 log lines (upstream's search fixture)
#   default.otel_traces             60 traces of three spans, web -> api -> worker
#   default.otel_metrics_gauge      CPU and memory gauges
#   default.otel_metrics_sum        a cumulative request counter and a delta queue counter
#   default.otel_metrics_histogram  a cumulative and a delta duration histogram
#
# The columns are upstream docs/clickstack.md sections 2, 5 and 6. The
# metrics rows are upstream's test/smolquery_clickhouse/hyperdx_metrics_test.exs
# generator, ported to awk: one point per minute from 2026-10-15 11:00 UTC,
# the hour upstream's hyperdx_metrics.json fixture queries, so the suite
# asserts the fixture's values here too. The traces and logs sit in their
# own fixed windows for the same reason. Every insert carries an insertId,
# so a re-run of the Job lands each row set once.
set -eu

api=http://smolquery:4000
auth='authorization: Bearer kind-only-api-key'
json='content-type: application/json'
ndjson='content-type: application/x-ndjson'

until curl -sSf -o /dev/null "$api/healthz"; do sleep 2; done

post() {
  curl -sS -o /dev/null -w "$1: %{http_code}\n" -H "$auth" -H "$json" -d "$2" "$api/v1/datasets$3"
}

cluster() {
  curl -sS -o /dev/null -w "clustering $1: %{http_code}\n" -X PATCH -H "$auth" -H "$json" \
    -d "{\"clustering\": $2}" "$api/v1/datasets/default/tables/$1"
}

insert() {
  status=$(curl -sS -o /tmp/insert.json -w '%{http_code}' -H "$auth" -H "$ndjson" \
    --data-binary "@/tmp/$1.ndjson" "$api/v1/datasets/default/tables/$1/insert?insertId=seed-$1-v2")
  echo "insert $1: $status $(wc -l < "/tmp/$1.ndjson") rows $(cat /tmp/insert.json)"
  [ "$status" = 200 ]
}

post 'dataset default' '{"id": "default"}' ''

# --- logs (docs/clickstack.md section 2) -----------------------------------

post 'table otel_logs' '{"id": "otel_logs", "schema": [
  {"name": "Timestamp", "type": "TIMESTAMP_NS", "nullable": false},
  {"name": "TraceId", "type": "STRING"},
  {"name": "SpanId", "type": "STRING"},
  {"name": "SeverityText", "type": "STRING"},
  {"name": "SeverityNumber", "type": "INT64"},
  {"name": "ServiceName", "type": "STRING"},
  {"name": "Body", "type": "STRING"},
  {"name": "ResourceAttributes", "type": "MAP(STRING, STRING)"},
  {"name": "ScopeName", "type": "STRING"},
  {"name": "LogAttributes", "type": "MAP(STRING, STRING)"}
]}' /default/tables
cluster otel_logs '["ServiceName", "Timestamp"]'

# 2026-09-19 10:11:00 plus one second per row, api and worker alternating,
# every fourth row an error with http.status 500.
awk 'BEGIN {
  for (i = 0; i < 120; i++) {
    ts = sprintf("2026-09-19T10:%02d:%02d.000000000Z", 11 + int(i / 60), i % 60)
    service = (i % 2 == 0) ? "api" : "worker"
    if (i % 4 == 0) {
      severity = "error"; number = 17; status = 500; body = "payment failed, id=" i " user_id=u" i
    } else {
      severity = "info"; number = 9; status = 200; body = "user login ok id=" i
    }
    printf "{\"Timestamp\":\"%s\",\"ServiceName\":\"%s\",\"SeverityText\":\"%s\",\"SeverityNumber\":%d,\"Body\":\"%s\",\"LogAttributes\":{\"http.status\":\"%d\"},\"ResourceAttributes\":{\"host.name\":\"%s-0\"},\"ScopeName\":\"seed\"}\n", ts, service, severity, number, body, status, service
  }
}' > /tmp/otel_logs.ndjson
insert otel_logs

# --- traces (docs/clickstack.md section 5) ---------------------------------

post 'table otel_traces' '{"id": "otel_traces", "schema": [
  {"name": "Timestamp", "type": "TIMESTAMP_NS", "nullable": false},
  {"name": "TraceId", "type": "STRING"},
  {"name": "SpanId", "type": "STRING"},
  {"name": "ParentSpanId", "type": "STRING"},
  {"name": "TraceState", "type": "STRING"},
  {"name": "SpanName", "type": "STRING"},
  {"name": "SpanKind", "type": "STRING"},
  {"name": "ServiceName", "type": "STRING"},
  {"name": "ResourceAttributes", "type": "MAP(STRING, STRING)"},
  {"name": "ScopeName", "type": "STRING"},
  {"name": "ScopeVersion", "type": "STRING"},
  {"name": "SpanAttributes", "type": "MAP(STRING, STRING)"},
  {"name": "Duration", "type": "INT64", "nullable": false},
  {"name": "StatusCode", "type": "STRING"},
  {"name": "StatusMessage", "type": "STRING"}
]}' /default/tables
cluster otel_traces '["ServiceName", "SpanName", "Timestamp"]'

# A span always has a duration, so Duration is not nullable and the edge
# answers it as a plain Int64, as the exporter's table does.
#
# One trace per minute from 2026-10-15 11:00 UTC: a web request that calls
# the api, which queries the worker. Durations are nanoseconds and step
# through five values, and every fifth trace fails at the web edge.
awk 'function span(t, k, ms, service, name, kind, parent, status, message, attrs,    ts) {
  ts = sprintf("2026-10-15T11:%02d:00.%03d000000Z", t, ms)
  printf "{\"Timestamp\":\"%s\",\"TraceId\":\"%032x\",\"SpanId\":\"%016x\",\"ParentSpanId\":\"%s\",\"TraceState\":\"\",\"SpanName\":\"%s\",\"SpanKind\":\"%s\",\"ServiceName\":\"%s\",\"ResourceAttributes\":{\"service.name\":\"%s\",\"host.name\":\"%s-1\"},\"ScopeName\":\"otel-seed\",\"ScopeVersion\":\"1.0.0\",\"SpanAttributes\":%s,\"Duration\":%d,\"StatusCode\":\"%s\",\"StatusMessage\":\"%s\"}\n", ts, t + 1, t * 10 + k, parent, name, kind, service, service, service, attrs, dur[k], status, message
}
BEGIN {
  for (t = 0; t < 60; t++) {
    dur[1] = (150 + (t % 5) * 40) * 1000000
    dur[2] = dur[1] - 30 * 1000000
    dur[3] = dur[2] - 40 * 1000000
    failed = (t % 5 == 4)
    web_status = failed ? "Error" : "Ok"
    web_message = failed ? "upstream timeout" : ""
    http_status = failed ? "500" : "200"
    span(t, 1, 0, "web", "POST /checkout", "Server", "", web_status, web_message, "{\"http.method\":\"POST\",\"http.route\":\"/checkout\",\"http.status_code\":\"" http_status "\"}")
    span(t, 2, 5, "api", "GET /v1/orders", "Server", sprintf("%016x", t * 10 + 1), "Ok", "", "{\"http.method\":\"GET\",\"http.route\":\"/v1/orders\"}")
    span(t, 3, 15, "worker", "SELECT orders", "Client", sprintf("%016x", t * 10 + 2), "Ok", "", "{\"db.system\":\"smolquery\",\"db.statement\":\"SELECT orders\"}")
  }
}' > /tmp/otel_traces.ndjson
insert otel_traces

# --- metrics (docs/clickstack.md section 6) --------------------------------

common='{"name": "ResourceAttributes", "type": "MAP(STRING, STRING)"},
  {"name": "ResourceSchemaUrl", "type": "STRING"},
  {"name": "ScopeName", "type": "STRING"},
  {"name": "ScopeVersion", "type": "STRING"},
  {"name": "ScopeAttributes", "type": "MAP(STRING, STRING)"},
  {"name": "ScopeDroppedAttrCount", "type": "INT64"},
  {"name": "ScopeSchemaUrl", "type": "STRING"},
  {"name": "ServiceName", "type": "STRING"},
  {"name": "MetricName", "type": "STRING"},
  {"name": "MetricDescription", "type": "STRING"},
  {"name": "MetricUnit", "type": "STRING"},
  {"name": "Attributes", "type": "MAP(STRING, STRING)"},
  {"name": "StartTimeUnix", "type": "TIMESTAMP"},
  {"name": "TimeUnix", "type": "TIMESTAMP", "nullable": false},
  {"name": "Flags", "type": "INT64"}'

metrics_table() {
  post "table $1" "{\"id\": \"$1\", \"schema\": [$common, $2]}" /default/tables
  cluster "$1" '["ServiceName", "MetricName", "TimeUnix"]'
}

metrics_table otel_metrics_gauge '{"name": "Value", "type": "FLOAT64"}'
metrics_table otel_metrics_sum '{"name": "Value", "type": "FLOAT64"},
  {"name": "AggregationTemporality", "type": "INT64"}, {"name": "IsMonotonic", "type": "BOOL"}'
metrics_table otel_metrics_histogram '{"name": "Count", "type": "INT64"}, {"name": "Sum", "type": "FLOAT64"},
  {"name": "BucketCounts", "type": "ARRAY<INT64>"}, {"name": "ExplicitBounds", "type": "ARRAY<FLOAT64>"},
  {"name": "Min", "type": "FLOAT64"}, {"name": "Max", "type": "FLOAT64"},
  {"name": "AggregationTemporality", "type": "INT64"}'

# The generator shared by the three tables. `pseudo` is upstream's: a
# deterministic value in [0, 1) from a seed and the minute.
metrics_awk='
function pseudo(seed, i) { return ((seed * 7919 + i * 104729) % 1000) / 1000 }
function common(service, name, unit, description, attrs, minute) {
  return sprintf("\"ResourceAttributes\":{\"service.name\":\"%s\",\"host.name\":\"%s-1\"},\"ResourceSchemaUrl\":\"\",\"ScopeName\":\"otel-seed\",\"ScopeVersion\":\"1.0.0\",\"ScopeAttributes\":{},\"ScopeDroppedAttrCount\":0,\"ScopeSchemaUrl\":\"\",\"ServiceName\":\"%s\",\"MetricName\":\"%s\",\"MetricDescription\":\"%s\",\"MetricUnit\":\"%s\",\"Attributes\":%s,\"StartTimeUnix\":\"2026-10-15T11:00:00Z\",\"TimeUnix\":\"2026-10-15T11:%02d:00Z\",\"Flags\":0", service, service, service, name, description, unit, attrs, minute)
}
function list(a, n,    s, b) { s = "["; for (b = 0; b < n; b++) s = s (b ? "," : "") a[b]; return s "]" }
BEGIN {
  services[0] = "api"; services[1] = "worker"; services[2] = "web"
  bounds = "[5.0,10.0,25.0,50.0,100.0,250.0,500.0,1000.0]"
}'

awk "$metrics_awk"'
BEGIN {
  for (s = 0; s < 3; s++) for (cpu = 0; cpu < 2; cpu++) for (i = 0; i < 60; i++)
    printf "{%s,\"Value\":%.4f}\n", common(services[s], "system.cpu.utilization", "1", "CPU busy fraction", "{\"cpu\":\"" cpu "\",\"state\":\"user\"}", i), 0.2 + 0.6 * pseudo(s + cpu, i)
  for (s = 0; s < 3; s++) for (i = 0; i < 60; i++)
    printf "{%s,\"Value\":%.1f}\n", common(services[s], "process.runtime.memory", "By", "Resident memory", "{\"type\":\"rss\"}", i), 100000000 + s * 10000000 + i * 60000.0
}' > /tmp/otel_metrics_gauge.ndjson
insert otel_metrics_gauge

awk "$metrics_awk"'
BEGIN {
  for (s = 0; s < 3; s++) for (st = 0; st < 2; st++) {
    status = st ? "500" : "200"; total = 0
    for (i = 0; i < 60; i++) {
      increment = st ? int(pseudo(s, i) * 3) : 5 + int(pseudo(s + 3, i) * 20)
      total = (services[s] == "worker" && i == 30) ? increment : total + increment
      printf "{%s,\"Value\":%.1f,\"AggregationTemporality\":2,\"IsMonotonic\":true}\n", common(services[s], "http.server.request.count", "{request}", "Requests served", "{\"status\":\"" status "\",\"route\":\"/v1/query\"}", i), total
    }
  }
  for (s = 0; s < 3; s++) for (i = 0; i < 60; i++)
    printf "{%s,\"Value\":%.1f,\"AggregationTemporality\":1,\"IsMonotonic\":false}\n", common(services[s], "queue.enqueued", "{job}", "Jobs enqueued per interval", "{\"queue\":\"default\"}", i), 1.0 + int(pseudo(s + 5, i) * 10)
}' > /tmp/otel_metrics_sum.ndjson
insert otel_metrics_sum

awk "$metrics_awk"'
BEGIN {
  for (s = 0; s < 3; s++) {
    for (b = 0; b < 9; b++) counts[b] = 0
    count = 0; total = 0.0
    for (i = 0; i < 60; i++) {
      added = 0
      for (b = 0; b < 9; b++) {
        increment = int(pseudo(s + b, i) * ((b >= 2 && b <= 4) ? 12 : 3))
        counts[b] += increment; added += increment
      }
      count += added; total += added * (20.0 + s * 5)
      printf "{%s,\"Count\":%d,\"Sum\":%.2f,\"BucketCounts\":%s,\"ExplicitBounds\":%s,\"Min\":1.5,\"Max\":980.0,\"AggregationTemporality\":2}\n", common(services[s], "http.server.duration", "ms", "Request duration", "{\"route\":\"/v1/query\"}", i), count, total, list(counts, 9), bounds
    }
  }
  for (s = 0; s < 3; s++) for (i = 0; i < 60; i++) {
    sum = 0
    for (b = 0; b < 9; b++) { delta[b] = int(pseudo(s + b + 1, i) * 5); sum += delta[b] }
    printf "{%s,\"Count\":%d,\"Sum\":%.1f,\"BucketCounts\":%s,\"ExplicitBounds\":%s,\"Min\":2.0,\"Max\":700.0,\"AggregationTemporality\":1}\n", common(services[s], "db.client.duration", "ms", "Query duration, delta", "{\"db\":\"lake\"}", i), sum, sum * 30.0, list(delta, 9), bounds
  }
}' > /tmp/otel_metrics_histogram.ndjson
insert otel_metrics_histogram
