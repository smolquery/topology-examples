defmodule Topology.Examples.SplitComputeTest do
  @moduledoc """
  The split-compute shape: an ingest front door, a query tier, a buffer
  fleet holding the unsealed tail, storage sealers, a Postgres catalog and
  RustFS as the sealed tier.

  Not run by `mix test`: `:split_compute` is excluded in `test_helper.exs`.
  Bring the example up with `mise run up split-compute`, then
  `mise run test split-compute`.

  The destructive tests restore the fleet in `on_exit` and take datasets of
  their own, so ExUnit's shuffling cannot make one depend on another.
  """

  use ExUnit.Case, async: false

  alias Topology.Api
  alias Topology.Eventually
  alias Topology.Example
  alias Topology.Kube
  alias Topology.ObjectStore

  @moduletag :split_compute
  @moduletag timeout: 900_000

  @example "split-compute"
  @namespace "split-compute"
  @query_pod "smolquery-query-0"
  @buffer_statefulset "statefulset/smolquery-buffer"
  @buffer_replicas 3
  @rows 200

  setup_all do
    Example.require_up!(@example)

    ingest = Example.api(@example, :api)
    query = Example.api(@example, :query_api)
    Api.await_healthy!(ingest)
    Api.await_healthy!(query)

    dataset = Api.unique_name("split")
    {first, second} = tables_on_distinct_owners(dataset)
    create_tables!(ingest, dataset, [first, second])
    insert!(ingest, dataset, first, 1..@rows)
    insert!(ingest, dataset, second, 1..@rows)

    %{ingest: ingest, query: query, dataset: dataset, first: first, second: second}
  end

  describe "roles are strictly local" do
    test "the ingest tier refuses a query", %{ingest: ingest, dataset: dataset, first: first} do
      response =
        Api.post!(ingest, "/v1/queries", %{"query" => "SELECT 1 FROM #{dataset}.#{first}"})

      assert response.status == 503
      assert response.body["error"]["message"] == "the query service is not available here"
    end

    test "the query tier refuses an insert", %{query: query, dataset: dataset, first: first} do
      assert_raise RuntimeError, ~r/503.*the write path is not available here/, fn ->
        Api.insert!(query, dataset, first, [%{"id" => 0, "v" => "refused"}])
      end
    end
  end

  describe "the fleet" do
    test "answers a query whose tables two different buffer nodes own", context do
      %{query: query, dataset: dataset, first: first, second: second} = context

      refute owner_pod(dataset, first) == owner_pod(dataset, second)
      assert total_rows(query, dataset, [first, second]) == {:ok, 2 * @rows}
    end

    test "seals to RustFS through the Postgres catalog and reads the rows back", context do
      %{query: query, dataset: dataset, first: first} = context

      unless Eventually.until(fn -> catalog_paths(dataset) != [] end, 60, 3_000) do
        flunk("""
        the Postgres catalog never listed a sealed file for #{dataset} within 180 s

        bucket objects: #{inspect(ObjectStore.keys(@namespace, dataset <> "/"))}
        storage logs:
        #{Kube.kubectl!(@namespace, ["logs", "-l", "app=smolquery-storage", "--tail=100", "--prefix"])}
        """)
      end

      assert ObjectStore.sealed?(@namespace, dataset),
             "no object for #{dataset} is in the smolquery-sealed bucket"

      assert Api.count(query, "SELECT sum(id) AS n FROM #{dataset}.#{first}") ==
               {:ok, Enum.sum(1..@rows)}

      assert Api.count(
               query,
               "SELECT count(*) - count(DISTINCT id) AS n FROM #{dataset}.#{first}"
             ) ==
               {:ok, 0}
    end
  end

  describe "the query tier is stateless" do
    test "keeps answering while one of its pods is replaced", context do
      %{query: query, dataset: dataset, first: first, second: second} = context

      on_exit(fn -> Kube.rollout_status!(@namespace, "statefulset/smolquery-query") end)

      Kube.kill!(@namespace, "smolquery-query-1")

      Eventually.until!(
        fn -> total_rows(query, dataset, [first, second]) == {:ok, 2 * @rows} end,
        30,
        2_000,
        "the query tier stopped answering while smolquery-query-1 was replaced"
      )
    end
  end

  describe "a buffer owner dying" do
    setup %{ingest: ingest} do
      dataset = Api.unique_name("kill")
      {first, second} = tables_on_distinct_owners(dataset)
      create_tables!(ingest, dataset, [first, second])
      insert!(ingest, dataset, first, 1..@rows)
      insert!(ingest, dataset, second, 1..@rows)

      %{dataset: dataset, first: first, second: second}
    end

    test "never shortens an answer: complete from the replica, or 503", context do
      %{query: query, dataset: dataset, first: first, second: second} = context

      victim = owner_pod(dataset, first)
      on_exit(fn -> await_fleet!() end)

      Kube.kill!(@namespace, victim)

      outcomes =
        for _attempt <- 1..10 do
          outcome = Api.count(query, "SELECT count(*) AS n FROM #{dataset}.#{first}")

          assert outcome in [{:ok, @rows}, {:error, 503}],
                 "while #{victim} was down a query answered #{inspect(outcome)}: " <>
                   "acked rows went missing silently rather than failing (T-94)"

          Process.sleep(2_000)
          outcome
        end

      assert {:ok, @rows} in outcomes,
             "no query answered completely while #{victim} was down; " <>
               "its replica holds every acked row"

      await_fleet!()

      Eventually.until!(
        fn -> total_rows(query, dataset, [first, second]) == {:ok, 2 * @rows} end,
        30,
        3_000,
        "the fleet did not answer every row after #{victim} came back"
      )
    end
  end

  defp create_tables!(api, dataset, tables) do
    Api.create_dataset!(api, dataset)

    for table <- tables do
      Api.create_table!(api, dataset, table, [
        %{"name" => "id", "type" => "INT64", "nullable" => false},
        %{"name" => "v", "type" => "STRING"}
      ])
    end
  end

  defp insert!(api, dataset, table, ids) do
    Api.insert!(api, dataset, table, for(i <- ids, do: %{"id" => i, "v" => "r#{i}"}))
  end

  defp total_rows(api, dataset, tables) do
    sums = Enum.map_join(tables, " + ", &"(SELECT count(*) FROM #{dataset}.#{&1})")
    Api.count(api, "SELECT #{sums} AS n")
  end

  defp catalog_paths(dataset) do
    psql!("""
    SELECT path FROM #{catalog_schema()}.ducklake_data_file
    WHERE path LIKE 's3://smolquery-sealed/%#{dataset}%'
    """)
  end

  defp catalog_schema do
    "SELECT table_schema FROM information_schema.tables WHERE table_name = 'ducklake_data_file'"
    |> psql!()
    |> case do
      [schema | _rest] -> ~s|"#{schema}"|
      [] -> raise "the Postgres catalog holds no ducklake_data_file table"
    end
  end

  defp psql!(sql) do
    @namespace
    |> Kube.kubectl!([
      "exec",
      "postgres-0",
      "--",
      "psql",
      "-At",
      "-U",
      "postgres",
      "smolquery",
      "-c",
      sql
    ])
    |> String.split("\n", trim: true)
  end

  defp owner_pod(dataset, table) do
    @namespace
    |> Kube.rpc!(
      @query_pod,
      ~s|IO.puts(Smolquery.BufferService.Client.owner(Smolquery.BufferService, {"#{dataset}", "#{table}"}))|
    )
    |> pod_of_node()
  end

  defp pod_of_node(node) do
    node |> String.split("@", parts: 2) |> List.last() |> String.split(".", parts: 2) |> hd()
  end

  defp tables_on_distinct_owners(dataset) do
    picked =
      Kube.rpc!(@namespace, @query_pod, """
      owner = fn i ->
        Smolquery.BufferService.Client.owner(Smolquery.BufferService, {"#{dataset}", "t" <> Integer.to_string(i)})
      end

      first = owner.(1)

      case Enum.find(2..500, fn i -> owner.(i) != first end) do
        nil -> IO.puts("NONE")
        i -> IO.puts("t1 t" <> Integer.to_string(i))
      end
      """)

    case String.split(picked, " ", trim: true) do
      [first, second] -> {first, second}
      _other -> raise "every candidate table hashed to one buffer node: #{picked}"
    end
  end

  defp ring_nodes do
    @namespace
    |> Kube.rpc!(
      @query_pod,
      ~s|IO.puts(Enum.join(Smolquery.BufferService.Client.nodes(Smolquery.BufferService), " "))|
    )
    |> String.split(" ", trim: true)
  end

  defp await_fleet! do
    Kube.rollout_status!(@namespace, @buffer_statefulset, 180)

    Eventually.until!(
      fn -> length(ring_nodes()) == @buffer_replicas end,
      60,
      1_000,
      "the buffer ring did not return to #{@buffer_replicas} members"
    )
  end
end
