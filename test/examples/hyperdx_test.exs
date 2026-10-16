defmodule Topology.Examples.HyperdxTest do
  @moduledoc """
  HyperDX on smolquery's ClickHouse edge: what HyperDX sends for its Search
  page, its trace screens and its metrics charts, replayed against the rows
  the seed Job wrote.

  The log and metrics statements are upstream's fixtures, verbatim from
  HyperDX's source (`test/support/fixtures/clickstack/hyperdx_search.json`
  and `hyperdx_metrics.json`), with each fixture's settings and `param_*`
  values in the URL and the `FORMAT` clause clickhouse-js appends. The
  search fixture's database and table parameters are swapped for the
  provisioned source's table; the metrics fixture names `default` and the
  `otel_metrics_*` tables already. The trace statements are shaped as
  HyperDX 2.41.0 composes them (upstream `scripts/hyperdx-probe/probe_traces.ts`),
  since upstream keeps no trace fixture yet. The seed rows are the
  fixtures', so their counts hold here too.

  Not run by `mix test`: `:hyperdx` is excluded in `test_helper.exs`. Bring
  the example up with `mise run up hyperdx`, then `mise run test hyperdx`.
  """

  use ExUnit.Case, async: false

  alias Topology.Api
  alias Topology.Example

  @moduletag :hyperdx
  @moduletag timeout: 600_000

  @example "hyperdx"
  @search_fixture "test/support/fixtures/clickstack/hyperdx_search.json"
  @metrics_fixture "test/support/fixtures/clickstack/hyperdx_metrics.json"
  @database_param "HYPERDX_PARAM_1544803905"
  @table_param "HYPERDX_PARAM_129845054"

  @window_start 1_792_062_000_000
  @window_end 1_792_065_600_000
  @window "(Timestamp >= fromUnixTimestamp64Milli(#{@window_start}) AND Timestamp <= fromUnixTimestamp64Milli(#{@window_end}))"
  @services ["api", "worker", "web"]

  setup_all do
    Example.require_up!(@example)
    @example |> Example.api() |> Api.await_healthy!()

    %{
      search: @search_fixture |> File.read!() |> JSON.decode!(),
      metrics: @metrics_fixture |> File.read!() |> JSON.decode!()
    }
  end

  test "HyperDX is up, and the edge answers its connection test" do
    health = Req.get!("http://localhost:#{Example.host_port(@example, :hyperdx)}/api/health")

    assert health.status == 200
    assert %{"data" => "OK"} = health.body

    probe =
      Req.get!(edge_url(),
        params: [query: "SELECT 1"],
        headers: [{"x-clickhouse-key", Example.api_key()}],
        retry: false
      )

    assert probe.status == 200
    assert String.trim(probe.body) == "1"
  end

  describe "logs: the Search page" do
    test "every statement HyperDX's Search page sends answers 200", %{search: fixture} do
      for %{"step" => step} <- fixture["steps"] do
        assert {:ok, _body} = run(fixture, step, "otel_logs"), "#{step} did not answer"
      end
    end

    test "the metadata HyperDX reads: columns, types, sorting key", %{search: fixture} do
      describe = json(fixture, "describe", "otel_logs")

      assert %{"name" => "Timestamp", "type" => "DateTime64(9)"} =
               Enum.find(describe["data"], &(&1["name"] == "Timestamp"))

      assert %{"name" => "LogAttributes", "type" => "Map(String, String)"} =
               Enum.find(describe["data"], &(&1["name"] == "LogAttributes"))

      assert [%{"engine" => "MergeTree", "sorting_key" => "ServiceName, Timestamp"}] =
               json(fixture, "table_metadata", "otel_logs")["data"]
    end

    test "the results table answers the seeded rows, newest first", %{search: fixture} do
      assert [names, _types | rows] = lines(fixture, "rows", "otel_logs")

      assert names == ["Timestamp", "ServiceName", "SeverityText", "Body"]
      assert length(rows) == 120

      assert ["2026-09-19T10:12:59.000000000Z", "worker", "info", "user login ok id=119"] =
               hd(rows)
    end

    test "the histogram counts errors and infos by minute", %{search: fixture} do
      assert %{"data" => data, "rows" => 4} = json(fixture, "histogram", "otel_logs")

      assert Enum.sort(Enum.map(data, &{&1["SeverityText"], &1["count()"]})) ==
               [{"error", "15"}, {"error", "15"}, {"info", "45"}, {"info", "45"}]
    end

    test "a term search and a map-key filter find the error lines", %{search: fixture} do
      assert [_names, _types | rows] = lines(fixture, "rows_term", "otel_logs")
      assert length(rows) == 30

      assert Enum.all?(rows, fn [_ts, _service, severity, body] ->
               severity == "error" and body =~ "payment"
             end)

      assert [%{"count()" => "30"}] = json(fixture, "count_field_filters", "otel_logs")["data"]
    end

    test "the filters sidebar: map keys and field values", %{search: fixture} do
      assert [%{"keysArr" => ["http.status"]}] = json(fixture, "map_keys", "otel_logs")["data"]

      assert %{"data" => [values]} = json(fixture, "key_values", "otel_logs")
      assert Enum.sort(values["param0"]) == ["api", "worker"]
      assert Enum.sort(values["param1"]) == ["error", "info"]
    end
  end

  describe "traces: search, the waterfall, latency charts and the service map" do
    test "the trace table's metadata: Duration is Int64, attributes a map, the sorting key",
         %{search: fixture} do
      describe = json(fixture, "describe", "otel_traces")

      assert %{"type" => "Int64"} = Enum.find(describe["data"], &(&1["name"] == "Duration"))

      assert %{"type" => "Map(String, String)"} =
               Enum.find(describe["data"], &(&1["name"] == "SpanAttributes"))

      assert [%{"sorting_key" => "ServiceName, SpanName, Timestamp"}] =
               json(fixture, "table_metadata", "otel_traces")["data"]
    end

    test "search in trace mode: a term, a phrase, a field, a map key and a duration range" do
      select =
        "SELECT Timestamp,ServiceName,StatusCode,round(Duration/1e6),SpanName FROM default.otel_traces"

      assert [names, _types | rows] =
               trace_lines(
                 "#{select} WHERE #{@window} AND ((hasToken(lower(SpanName), lower('checkout')))) " <>
                   "ORDER BY Timestamp DESC LIMIT 200 OFFSET 0"
               )

      assert Enum.take(names, 3) == ["Timestamp", "ServiceName", "StatusCode"]
      assert List.last(names) == "SpanName"
      assert length(rows) == 60

      assert Enum.all?(rows, fn [_ts, service, _status, _ms, name] ->
               {service, name} == {"web", "POST /checkout"}
             end)

      assert trace_count("SpanName ILIKE '%SELECT orders%'") == 60
      assert trace_count("StatusCode = 'Error'") == 12
      assert trace_count("SpanKind = 'Server'") == 120

      assert trace_count(
               "`SpanAttributes`['http.method'] = 'POST' AND indexHint(mapContains(`SpanAttributes`, 'http.method'))"
             ) == 60

      assert trace_count("Duration >= 100000000 AND Duration <= 300000000") == 156
    end

    test "the histogram by StatusCode and the p95 latency by service, per five minutes" do
      histogram =
        trace_json(
          "SELECT count(),StatusCode,toStartOfInterval(toDateTime(Timestamp), INTERVAL 5 minute) AS `__hdx_time_bucket` " <>
            "FROM default.otel_traces WHERE #{@window} " <>
            "GROUP BY StatusCode,toStartOfInterval(toDateTime(Timestamp), INTERVAL 5 minute) AS `__hdx_time_bucket` " <>
            "ORDER BY toStartOfInterval(toDateTime(Timestamp), INTERVAL 5 minute) AS `__hdx_time_bucket` LIMIT 100000"
        )

      assert histogram["rows"] == 24

      assert histogram["data"]
             |> Enum.map(&{&1["StatusCode"], &1["count()"]})
             |> Enum.uniq()
             |> Enum.sort() ==
               [{"Error", "1"}, {"Ok", "14"}]

      p95 =
        trace_json(
          "SELECT quantile(0.95)(Duration),ServiceName,toStartOfInterval(toDateTime(Timestamp), INTERVAL 5 minute) AS `__hdx_time_bucket` " <>
            "FROM default.otel_traces WHERE #{@window} " <>
            "GROUP BY ServiceName,toStartOfInterval(toDateTime(Timestamp), INTERVAL 5 minute) AS `__hdx_time_bucket` " <>
            "ORDER BY toStartOfInterval(toDateTime(Timestamp), INTERVAL 5 minute) AS `__hdx_time_bucket` LIMIT 100000"
        )

      assert p95["rows"] == 36

      assert p95["data"] |> Enum.map(& &1["ServiceName"]) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(@services)

      [value_column | _rest] = Enum.map(p95["meta"], & &1["name"])

      assert Enum.all?(p95["data"], fn row ->
               value = to_number(row[value_column])
               value >= 80_000_000 and value <= 310_000_000
             end)
    end

    test "the waterfall: one trace's spans, parented web -> api -> worker" do
      trace_id = String.pad_leading("1", 32, "0")

      waterfall =
        trace_json(
          "SELECT Timestamp,Duration,SpanName,ServiceName,SpanId,ParentSpanId,StatusCode " <>
            "FROM default.otel_traces WHERE TraceId = '#{trace_id}' ORDER BY Timestamp ASC"
        )

      assert [web, api, worker] = waterfall["data"]

      assert {web["ServiceName"], web["SpanName"], web["ParentSpanId"]} ==
               {"web", "POST /checkout", ""}

      assert {api["ServiceName"], api["ParentSpanId"]} == {"api", web["SpanId"]}
      assert {worker["ServiceName"], worker["ParentSpanId"]} == {"worker", api["SpanId"]}
      assert to_number(web["Duration"]) > to_number(api["Duration"])
    end

    test "the service map's quantiles answer three percentiles per service as one array" do
      map =
        trace_json(
          "SELECT ServiceName, quantiles(0.5, 0.95, 0.99)(Duration) AS quantiles, count() AS spans " <>
            "FROM default.otel_traces WHERE #{@window} GROUP BY ServiceName ORDER BY ServiceName"
        )

      assert map["rows"] == 3

      assert Enum.find(map["meta"], &(&1["name"] == "quantiles"))["type"] ==
               "Array(Nullable(Float64))"

      for row <- map["data"] do
        assert row["spans"] == "60"
        assert [p50, p95, p99] = row["quantiles"]
        assert p50 <= p95 and p95 <= p99
      end
    end
  end

  describe "metrics: the catalog and the chart builder" do
    test "every statement HyperDX's metrics screens send answers 200", %{metrics: fixture} do
      for %{"step" => step} <- fixture["steps"] do
        assert {:ok, _body} = run(fixture, step), "#{step} did not answer"
      end
    end

    test "the metric catalog, name search, and a metric's unit, attributes and values",
         %{metrics: fixture} do
      assert json(fixture, "catalog_gauge")["data"] == [
               %{
                 "MetricName" => "process.runtime.memory",
                 "MetricUnit" => "By",
                 "MetricDescription" => "Resident memory"
               },
               %{
                 "MetricName" => "system.cpu.utilization",
                 "MetricUnit" => "1",
                 "MetricDescription" => "CPU busy fraction"
               }
             ]

      assert Enum.map(json(fixture, "catalog_sum")["data"], & &1["MetricName"]) ==
               ["http.server.request.count", "queue.enqueued"]

      assert Enum.map(json(fixture, "catalog_histogram")["data"], & &1["MetricName"]) ==
               ["db.client.duration", "http.server.duration"]

      assert json(fixture, "metric_metadata")["data"] ==
               [%{"MetricUnit" => "1", "MetricDescription" => "CPU busy fraction"}]

      attributes = json(fixture, "metric_attributes")
      assert attributes["rows"] == 6
      assert types(attributes) == List.duplicate("Map(String, String)", 3)

      assert json(fixture, "metric_attribute_values")["data"] == [
               %{"value" => "0"},
               %{"value" => "1"}
             ]
    end

    test "gauge charts: averaged, maxed, filtered, grouped by an attribute, as a delta",
         %{metrics: fixture} do
      averaged = json(fixture, "gauge_avg_by_service")

      assert types(averaged) == ["Float64", "Nullable(String)", "DateTime64(6)"]
      assert Enum.drop(names(averaged), 1) == ["ServiceName", "__hdx_time_bucket"]
      assert averaged["rows"] == 36
      assert Enum.all?(values(averaged, hd(names(averaged))), &(&1 >= 0.2 and &1 <= 0.8))
      assert hd(averaged["data"])["__hdx_time_bucket"] == "2026-10-15T11:00:00.000000Z"

      maxed = json(fixture, "gauge_max_number")
      assert types(maxed) == ["Nullable(Float64)"]
      assert [max] = values(maxed, hd(names(maxed)))
      assert max > 0.7 and max <= 0.8

      filtered = json(fixture, "gauge_avg_filtered")
      assert types(filtered) == ["Float64", "DateTime64(6)"]
      assert filtered["rows"] == 12

      by_attribute = json(fixture, "gauge_by_attribute")
      assert types(by_attribute) == ["Float64", "Nullable(String)", "DateTime64(6)"]

      assert by_attribute["data"]
             |> Enum.map(& &1["Attributes['cpu']"])
             |> Enum.uniq()
             |> Enum.sort() ==
               ["0", "1"]

      delta = json(fixture, "gauge_delta")
      assert types(delta) == ["Float64", "Nullable(String)", "DateTime64(6)"]
      assert Enum.all?(values(delta, hd(names(delta))), &(&1 > 0))
    end

    test "sum charts: a counter's rate, its increase with top groups, its last value, a delta counter",
         %{metrics: fixture} do
      rate = json(fixture, "sum_rate_by_service")

      assert names(rate) == ["Value", "ServiceName", "__hdx_time_bucket"]
      assert types(rate) == ["Float64", "Nullable(String)", "DateTime64(6)"]
      assert rate["rows"] == 36
      assert Enum.all?(values(rate, "Value"), &(&1 >= 0))

      increase = json(fixture, "sum_increase_by_service")
      assert types(increase) == ["Float64", "Nullable(String)", "DateTime64(6)"]
      assert increase["rows"] == 36
      assert Enum.sum(values(increase, "Value")) == Enum.sum(values(rate, "Value"))

      number = json(fixture, "sum_increase_number")
      assert types(number) == ["Nullable(Float64)"]
      assert [total] = values(number, "Value")
      assert total == Enum.sum(values(rate, "Value"))

      last = json(fixture, "sum_last_value")
      assert types(last) == ["Nullable(Float64)", "Nullable(String)", "DateTime64(6)"]
      assert Enum.all?(values(last, "Value"), &(&1 > 0))

      delta = json(fixture, "sum_delta_temporality")
      assert types(delta) == ["Float64", "DateTime64(6)"]
      assert delta["rows"] == 12
      assert Enum.all?(values(delta, "Value"), &(&1 >= 15 and &1 <= 150))
    end

    test "histogram charts: quantiles from bucket deltas, and counts", %{metrics: fixture} do
      p95 = json(fixture, "histogram_p95_by_service")

      assert names(p95) == ["__hdx_time_bucket", "group", "Value"]
      assert types(p95) == ["DateTime64(6)", "Array(Nullable(String))", "Nullable(Float64)"]

      assert p95["data"] |> Enum.map(& &1["group"]) |> Enum.uniq() |> Enum.sort() ==
               Enum.map(Enum.sort(@services), &[&1])

      assert Enum.all?(values(p95, "Value"), &(&1 > 25 and &1 <= 1000))

      p50 = json(fixture, "histogram_p50_number")
      assert types(p50) == ["Nullable(Float64)"]
      assert [median] = values(p50, "Value")
      assert median > 10 and median < 100

      count = json(fixture, "histogram_count")
      assert names(count) == ["__hdx_time_bucket", "Value"]
      assert types(count) == ["DateTime64(6)", "Nullable(Int128)"]
      assert count["rows"] == 12
      assert Enum.sum(values(count, "Value")) == expected_histogram_count()

      by_service = json(fixture, "histogram_count_by_service")
      assert types(by_service) == ["DateTime64(6)", "Array(Nullable(String))", "Nullable(Int128)"]
      assert by_service["rows"] == 36
      assert Enum.sum(values(by_service, "Value")) == expected_histogram_count()
    end

    test "multi-series charts: two metrics pivoted per bucket, a ratio, a formula, a histogram beside a gauge",
         %{metrics: fixture} do
      pivot = json(fixture, "multi_gauge_sum")

      assert names(pivot) == ["cpu", "reqs", "ServiceName", "__hdx_time_bucket"]

      assert types(pivot) == [
               "Nullable(Float64)",
               "Nullable(Float64)",
               "Nullable(String)",
               "DateTime64(6)"
             ]

      assert pivot["rows"] == 36
      assert Enum.all?(values(pivot, "cpu"), &(&1 >= 0.2 and &1 <= 0.8))

      ratio = json(fixture, "multi_ratio")
      assert types(ratio) == ["Nullable(Float64)", "DateTime64(6)"]
      assert ratio["rows"] == 12
      assert Enum.all?(values(ratio, hd(names(ratio))), &(&1 >= 0 and &1 <= 1))

      formula = json(fixture, "multi_formula")
      assert Enum.at(names(formula), 2) == "error_pct"

      assert types(formula) == [
               "Nullable(Float64)",
               "Nullable(Float64)",
               "Nullable(Float64)",
               "DateTime64(6)"
             ]

      assert Enum.all?(values(formula, "error_pct"), &(&1 >= 0 and &1 <= 100))

      packed = json(fixture, "multi_gauge_histogram")

      assert types(packed) == [
               "Nullable(Float64)",
               "Nullable(Float64)",
               "Nullable(String)",
               "DateTime64(6)",
               "Array(Nullable(String))"
             ]

      assert packed["rows"] == 72
    end
  end

  defp run(fixture, step, table \\ nil) do
    %{"sql" => sql, "format" => format, "params" => params} =
      Enum.find(fixture["steps"], &(&1["step"] == step))

    params = if table, do: swap_table(params, table), else: params

    query =
      fixture["settings"]
      |> Map.merge(Map.new(params, fn {key, value} -> {"param_" <> key, value} end))
      |> Map.put("query_id", "hyperdx-#{step}")

    edge(sql <> " \nFORMAT " <> format, query)
  end

  defp swap_table(params, table) do
    params
    |> Map.replace(@database_param, "default")
    |> Map.replace(@table_param, table)
  end

  defp edge(body, query) do
    response =
      Req.post!(edge_url(),
        params: query,
        body: body,
        headers: [{"x-clickhouse-user", "default"}, {"x-clickhouse-key", Example.api_key()}],
        retry: false,
        receive_timeout: 60_000,
        decode_body: false
      )

    case response do
      %{status: 200, body: body} -> {:ok, body}
      %{status: status, body: body} -> {:error, {status, body}}
    end
  end

  defp json(fixture, step, table \\ nil) do
    {:ok, body} = run(fixture, step, table)
    JSON.decode!(body)
  end

  defp lines(fixture, step, table) do
    {:ok, body} = run(fixture, step, table)
    body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp trace_statement(sql, format) do
    {:ok, body} =
      edge(sql <> " \nFORMAT " <> format, %{
        "date_time_output_format" => "iso",
        "output_format_json_quote_64bit_integers" => "1"
      })

    body
  end

  defp trace_json(sql), do: sql |> trace_statement("JSON") |> JSON.decode!()

  defp trace_lines(sql) do
    sql
    |> trace_statement("JSONCompactEachRowWithNamesAndTypes")
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp trace_count(where) do
    [%{"count()" => count}] =
      trace_json("SELECT count() FROM default.otel_traces WHERE #{@window} AND ((#{where}))")[
        "data"
      ]

    to_number(count)
  end

  defp types(%{"meta" => meta}), do: Enum.map(meta, & &1["type"])
  defp names(%{"meta" => meta}), do: Enum.map(meta, & &1["name"])
  defp values(%{"data" => data}, column), do: Enum.map(data, &to_number(&1[column]))

  defp to_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _not_an_integer -> String.to_float(value)
    end
  end

  defp to_number(value), do: value

  defp pseudo(seed, i), do: rem(seed * 7919 + i * 104_729, 1000) / 1000

  defp bucket_increment(s, b, i) when b in 2..4, do: trunc(pseudo(s + b, i) * 12)
  defp bucket_increment(s, b, i), do: trunc(pseudo(s + b, i) * 3)

  defp expected_histogram_count do
    for s <- 0..(length(@services) - 1), reduce: 0 do
      total ->
        increments = for i <- 1..59, b <- 0..8, do: bucket_increment(s, b, i)
        total + Enum.sum(increments)
    end
  end

  defp edge_url, do: "http://localhost:#{Example.host_port(@example, :clickhouse)}/"
end
