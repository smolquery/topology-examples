defmodule Topology.Examples.SingleNodeTest do
  @moduledoc """
  The single-node shape: one pod, every role, every edge, one volume.

  Not run by `mix test`: `:single_node` is excluded in `test_helper.exs`.
  Bring the example up with `mise run up single-node`, then
  `mise run test single-node`.
  """

  use ExUnit.Case, async: false

  alias Topology.Api
  alias Topology.Eventually
  alias Topology.Example
  alias Topology.Kube

  @moduletag :single_node
  @moduletag timeout: 600_000

  @example "single-node"
  @rows 200

  setup_all do
    Example.require_up!(@example)

    api = Example.api(@example)
    Api.await_healthy!(api)

    dataset = Api.unique_name("single")
    Api.create_dataset!(api, dataset)

    Api.create_table!(api, dataset, "events", [
      %{"name" => "id", "type" => "INT64", "nullable" => false},
      %{"name" => "v", "type" => "STRING"}
    ])

    Api.insert!(api, dataset, "events", for(i <- 1..@rows, do: %{"id" => i, "v" => "r#{i}"}))

    %{api: api, dataset: dataset}
  end

  test "the API round trip: every inserted row is queryable", %{api: api, dataset: dataset} do
    assert Api.count(api, "SELECT count(*) AS n FROM #{dataset}.events") == {:ok, @rows}
  end

  test "the Postgres wire listener reads the same rows", %{dataset: dataset} do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: "localhost",
        port: Example.host_port(@example, :pg),
        username: "smolquery",
        password: Example.api_key(),
        database: "smolquery",
        ssl: false
      )

    %Postgrex.Result{rows: [[count]]} =
      Postgrex.query!(conn, "SELECT count(*) FROM #{dataset}.events", [])

    assert count == @rows
  end

  test "the ClickHouse edge answers HyperDX's connection test" do
    response =
      Req.get!("http://localhost:#{Example.host_port(@example, :clickhouse)}/",
        params: [query: "SELECT 1"],
        headers: [{"x-clickhouse-key", Example.api_key()}],
        retry: false
      )

    assert response.status == 200
    assert String.trim(response.body) == "1"
  end

  test "the VictoriaMetrics edge answers Grafana's buildinfo" do
    response =
      Req.get!(
        "http://localhost:#{Example.host_port(@example, :victoriametrics)}/api/v1/status/buildinfo",
        headers: [{"authorization", "Bearer #{Example.api_key()}"}],
        retry: false
      )

    assert response.status == 200
    assert %{"status" => "success", "data" => %{"version" => _version}} = response.body
  end

  test "rows acked before a restart are all there after it", %{api: api, dataset: dataset} do
    namespace = Example.namespace(@example)

    Kube.restart!(namespace, "smolquery-0")
    Kube.rollout_status!(namespace, "statefulset/smolquery")
    Api.await_healthy!(api)

    Eventually.until!(
      fn -> Api.count(api, "SELECT count(*) AS n FROM #{dataset}.events") == {:ok, @rows} end,
      30,
      2_000,
      "#{dataset}.events did not count #{@rows} rows after the restart"
    )
  end
end
