defmodule Topology.Examples.HyperdxTest do
  @moduledoc """
  HyperDX on smolquery's ClickHouse edge: what HyperDX sends to open its
  Search page, replayed against the rows the seed Job wrote.

  The statements are upstream's fixture, verbatim from HyperDX's source
  (`test/support/fixtures/clickstack/hyperdx_search.json`), with the
  fixture's settings and `param_*` values in the URL and the `FORMAT`
  clause clickhouse-js appends. Only the database and table parameters are
  swapped for `default.otel_logs`, the table HyperDX's provisioned source
  reads. The seed rows are the fixture's, so its counts hold here too.

  Not run by `mix test`: `:hyperdx` is excluded in `test_helper.exs`. Bring
  the example up with `mise run up hyperdx`, then `mise run test hyperdx`.
  """

  use ExUnit.Case, async: false

  alias Topology.Api
  alias Topology.Example

  @moduletag :hyperdx
  @moduletag timeout: 600_000

  @example "hyperdx"
  @fixture "test/support/fixtures/clickstack/hyperdx_search.json"
  @database_param "HYPERDX_PARAM_1544803905"
  @table_param "HYPERDX_PARAM_129845054"

  setup_all do
    Example.require_up!(@example)
    @example |> Example.api() |> Api.await_healthy!()

    %{fixture: @fixture |> File.read!() |> JSON.decode!()}
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

  test "every statement HyperDX's Search page sends answers 200", %{fixture: fixture} do
    for %{"step" => step} <- fixture["steps"] do
      assert {:ok, _body} = run(fixture, step), "#{step} did not answer"
    end
  end

  test "the metadata HyperDX reads: columns, types, sorting key", %{fixture: fixture} do
    describe = json(fixture, "describe")

    assert %{"name" => "Timestamp", "type" => "DateTime64(9)"} =
             Enum.find(describe["data"], &(&1["name"] == "Timestamp"))

    assert %{"name" => "LogAttributes", "type" => "Map(String, String)"} =
             Enum.find(describe["data"], &(&1["name"] == "LogAttributes"))

    assert [%{"engine" => "MergeTree", "sorting_key" => "ServiceName, Timestamp"}] =
             json(fixture, "table_metadata")["data"]
  end

  test "the results table answers the seeded rows, newest first", %{fixture: fixture} do
    assert [names, _types | rows] = lines(fixture, "rows")

    assert names == ["Timestamp", "ServiceName", "SeverityText", "Body"]
    assert length(rows) == 120
    assert ["2026-09-19T10:12:59.000000000Z", "worker", "info", "user login ok id=119"] = hd(rows)
  end

  test "the histogram counts errors and infos by minute", %{fixture: fixture} do
    assert %{"data" => data, "rows" => 4} = json(fixture, "histogram")

    assert Enum.sort(Enum.map(data, &{&1["SeverityText"], &1["count()"]})) ==
             [{"error", "15"}, {"error", "15"}, {"info", "45"}, {"info", "45"}]
  end

  test "a term search and a map-key filter find the error lines", %{fixture: fixture} do
    assert [_names, _types | rows] = lines(fixture, "rows_term")
    assert length(rows) == 30

    assert Enum.all?(rows, fn [_ts, _service, severity, body] ->
             severity == "error" and body =~ "payment"
           end)

    assert [%{"count()" => "30"}] = json(fixture, "count_field_filters")["data"]
  end

  test "the filters sidebar: map keys and field values", %{fixture: fixture} do
    assert [%{"keysArr" => ["http.status"]}] = json(fixture, "map_keys")["data"]

    assert %{"data" => [values]} = json(fixture, "key_values")
    assert Enum.sort(values["param0"]) == ["api", "worker"]
    assert Enum.sort(values["param1"]) == ["error", "info"]
  end

  defp run(fixture, step) do
    %{"sql" => sql, "format" => format, "params" => params} =
      Enum.find(fixture["steps"], &(&1["step"] == step))

    params =
      params
      |> Map.replace(@database_param, "default")
      |> Map.replace(@table_param, "otel_logs")

    query =
      fixture["settings"]
      |> Map.merge(Map.new(params, fn {key, value} -> {"param_" <> key, value} end))
      |> Map.put("query_id", "hyperdx-#{step}")

    response =
      Req.post!(edge_url(),
        params: query,
        body: sql <> " \nFORMAT " <> format,
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

  defp json(fixture, step) do
    {:ok, body} = run(fixture, step)
    JSON.decode!(body)
  end

  defp lines(fixture, step) do
    {:ok, body} = run(fixture, step)
    body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp edge_url, do: "http://localhost:#{Example.host_port(@example, :clickhouse)}/"
end
