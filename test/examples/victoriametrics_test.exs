defmodule Topology.Examples.VictoriaMetricsTest do
  @moduledoc """
  smolquery as the metrics store: vmagent writes in, Grafana reads back.

  Not run by `mix test`: `:victoriametrics` is excluded in `test_helper.exs`.
  Bring the example up with `mise run up victoriametrics`, then
  `mise run test victoriametrics`.

  The idempotency test sends a Prometheus remote write 1.0 block of its own,
  encoded by hand: `WriteRequest { repeated TimeSeries timeseries = 1 }`,
  `TimeSeries { repeated Label labels = 1; repeated Sample samples = 2 }`,
  `Label { string name = 1; string value = 2 }`, `Sample { double value = 1;
  int64 timestamp = 2 }`, sent with no `Content-Encoding`, which the edge
  reads as is.
  """

  use ExUnit.Case, async: false

  import Bitwise

  alias Topology.Api
  alias Topology.Eventually
  alias Topology.Example

  @moduletag :victoriametrics
  @moduletag timeout: 600_000

  @example "victoriametrics"
  @grafana_credential {"admin", "kind-only-grafana-password"}

  setup_all do
    Example.require_up!(@example)

    api = Example.api(@example)
    Api.await_healthy!(api)

    Eventually.until!(
      fn ->
        match?({:ok, n} when n > 0, Api.count(api, "SELECT count(*) AS n FROM metrics.samples"))
      end,
      60,
      2_000,
      "no scraped sample reached metrics.samples"
    )

    %{api: api}
  end

  test "up answers 1 for the scrape targets" do
    assert {:ok, %{"resultType" => "vector", "result" => result}} = edge_query("up")
    assert result != []
    assert Enum.all?(result, fn %{"value" => [_ts, value]} -> value == "1" end)
    assert Enum.any?(result, &(get_in(&1, ["metric", "job"]) == "smolquery"))
  end

  test "query_range over a rate answers points" do
    now = System.system_time(:second)

    assert {:ok, %{"resultType" => "matrix", "result" => result}} =
             edge_get("/api/v1/query_range",
               query: "sum by (job) (rate(vm_promscrape_scrapes_total[1m]))",
               start: now - 300,
               end: now,
               step: 15
             )

    assert [%{"values" => [_point | _rest]} | _series] = result
  end

  test "the label routes answer" do
    assert {:ok, labels} = edge_get("/api/v1/labels")
    assert "job" in labels
    assert "__name__" in labels

    assert {:ok, jobs} = edge_get("/api/v1/label/job/values")
    assert "smolquery" in jobs
    assert "vmagent" in jobs
  end

  test "Grafana's provisioned datasource passes its health check" do
    {user, password} = @grafana_credential
    base = "http://localhost:#{Example.host_port(@example, :grafana)}"

    Eventually.until!(
      fn -> match?(%{status: 200}, Req.get!(base <> "/api/health", retry: false)) end,
      30,
      2_000,
      "Grafana never became healthy"
    )

    response =
      Req.get!(base <> "/api/datasources/uid/smolquery/health",
        auth: {:basic, "#{user}:#{password}"},
        retry: false,
        receive_timeout: 60_000
      )

    assert response.status == 200, inspect(response.body)
    assert %{"status" => "OK"} = response.body
  end

  test "a remote-write block sent twice is written once", %{api: api} do
    name = "topology_idempotent_#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)
    samples = for i <- 0..2, do: {now - (2 - i) * 1_000, i * 1.5}

    body = write_request([{[{"__name__", name}, {"job", "suite"}], samples}])

    for _attempt <- 1..2 do
      response =
        Req.post!(
          "http://localhost:#{Example.host_port(@example, :victoriametrics)}/api/v1/write",
          body: body,
          headers: [
            {"authorization", "Bearer #{Example.api_key()}"},
            {"content-type", "application/x-protobuf"}
          ],
          retry: false
        )

      assert response.status == 204, inspect(response.body)
    end

    assert Api.count(api, "SELECT count(*) AS n FROM metrics.samples WHERE name = '#{name}'") ==
             {:ok, length(samples)}
  end

  defp edge_query(query), do: edge_get("/api/v1/query", query: query)

  defp edge_get(path, params \\ []) do
    response =
      Req.get!("http://localhost:#{Example.host_port(@example, :victoriametrics)}" <> path,
        params: params,
        headers: [{"authorization", "Bearer #{Example.api_key()}"}],
        retry: false,
        receive_timeout: 60_000
      )

    case response.body do
      %{"status" => "success", "data" => data} -> {:ok, data}
      other -> {:error, response.status, other}
    end
  end

  defp write_request(series), do: Enum.map_join(series, &timeseries/1)

  defp timeseries({labels, samples}) do
    labels = Enum.map_join(Enum.sort(labels), fn {name, value} -> label(name, value) end)
    bytes(1, labels <> Enum.map_join(samples, fn {ts, value} -> sample(ts, value) end))
  end

  defp varint(n) when n < 0x80, do: <<n>>
  defp varint(n), do: <<1::1, n &&& 0x7F::7, varint(n >>> 7)::binary>>

  defp bytes(field, value), do: varint(field <<< 3 ||| 2) <> varint(byte_size(value)) <> value

  defp label(name, value), do: bytes(1, bytes(1, name) <> bytes(2, value))

  defp sample(timestamp, value),
    do: bytes(2, varint(9) <> <<value * 1.0::float-little-64>> <> varint(16) <> varint(timestamp))
end
