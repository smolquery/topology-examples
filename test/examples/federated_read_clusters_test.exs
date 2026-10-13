defmodule Topology.Examples.FederatedReadClustersTest do
  @moduledoc """
  One writer, two readers, one lake.

  Not run by `mix test`: `:federated_read_clusters` is excluded in
  `test_helper.exs`. Bring the example up with
  `mise run up federated-read-clusters`, then
  `mise run test federated-read-clusters`.

  A reader names the lake's own data path, `/data/ducklake`, which its
  release allows through `SMOLQUERY_FEDERATION_LOCAL_ROOTS` (upstream T-650,
  v0.23.0). Before that release every registration answered 400.
  """

  use ExUnit.Case, async: false

  alias Topology.Api
  alias Topology.Eventually
  alias Topology.Example
  alias Topology.Kube
  alias Topology.ObjectStore

  @moduletag :federated_read_clusters
  @moduletag timeout: 900_000

  @example "federated-read-clusters"
  @rows 300
  @readers [reader_1_api: "reader-1", reader_2_api: "reader-2"]
  @lake %{
    "name" => "writer",
    "kind" => "ducklake",
    "host" => "postgres",
    "port" => 5432,
    "database" => "smolquery",
    "username" => "postgres",
    "password" => "postgres",
    "sslmode" => "disable",
    "data_path" => "/data/ducklake"
  }

  setup_all do
    Example.require_up!(@example)

    namespace = Example.namespace(@example)
    writer = Example.api(@example)
    Api.await_healthy!(writer)

    readers = for {service, pod} <- @readers, do: {pod, Example.api(@example, service)}
    for {_pod, reader} <- readers, do: Api.await_healthy!(reader)

    dataset = Api.unique_name("lake")
    Api.create_dataset!(writer, dataset)

    Api.create_table!(writer, dataset, "events", [
      %{"name" => "id", "type" => "INT64", "nullable" => false},
      %{"name" => "v", "type" => "STRING"}
    ])

    Api.insert!(writer, dataset, "events", for(i <- 1..@rows, do: %{"id" => i, "v" => "r#{i}"}))

    Eventually.until!(
      fn -> ObjectStore.sealed?(namespace, dataset) end,
      40,
      5_000,
      "#{dataset} never sealed into the object store"
    )

    %{namespace: namespace, writer: writer, readers: readers, dataset: dataset}
  end

  test "the writer answers its own rows, hot tier and sealed tier as one", context do
    %{writer: writer, dataset: dataset} = context

    assert Api.count(writer, "SELECT count(*) AS n FROM #{dataset}.events") == {:ok, @rows}
  end

  test "each reader registers the writer's lake at the writer's own data path",
       %{readers: readers} do
    for {pod, reader} <- readers do
      response = Api.post!(reader, "/v1/connections", @lake)
      assert response.status in [200, 201], "#{pod}: #{inspect(response.body)}"
      assert response.body["kind"] == "ducklake"
      assert response.body["dataPath"] == "/data/ducklake"
    end
  end

  describe "with the lake registered" do
    setup %{readers: readers} do
      for {_pod, reader} <- readers do
        %{status: status} = Api.post!(reader, "/v1/connections", @lake)
        true = status in [200, 201]
      end

      :ok
    end

    test "rows sealed at the writer are read from both readers", context do
      %{readers: readers, dataset: dataset} = context

      for {pod, reader} <- readers do
        assert Api.count(reader, "SELECT count(*) AS n FROM writer.#{dataset}.events") ==
                 {:ok, @rows},
               "#{pod} did not read every sealed row"
      end
    end

    test "a reader joins lake rows with rows of its own", context do
      %{readers: [{_pod, reader} | _rest], dataset: dataset} = context

      sql = """
      SELECT count(*) AS n
        FROM writer.#{dataset}.events e
        JOIN (VALUES (1), (2), (3)) AS mine(id) ON mine.id = e.id
      """

      assert Api.count(reader, sql) == {:ok, 3}
    end

    test "a reader going away changes nothing for the writer or the other reader", context do
      %{namespace: namespace, writer: writer, readers: readers, dataset: dataset} = context
      [{survivor, reader_1}, {victim, reader_2}] = readers
      victim_pod = "#{victim}-0"
      victim_uid = Kube.pod_uid(namespace, victim_pod)

      on_exit(fn ->
        Kube.await_replacement!(namespace, victim_pod, victim_uid)
        Kube.rollout_status!(namespace, "statefulset/#{victim}")
        Api.await_healthy!(reader_2)
      end)

      Kube.kill!(namespace, victim_pod)

      assert Api.count(writer, "SELECT count(*) AS n FROM #{dataset}.events") == {:ok, @rows}

      assert Api.count(reader_1, "SELECT count(*) AS n FROM writer.#{dataset}.events") ==
               {:ok, @rows},
             "#{survivor} was disturbed by #{victim} going away"
    end
  end
end
