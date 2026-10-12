defmodule Topology.Examples.PostgresFdwTest do
  @moduledoc """
  OLTP and OLAP joined from Postgres over `postgres_fdw`, and from smolquery
  over a registered federated connection.

  Not run by `mix test`: `:postgres_fdw` is excluded in `test_helper.exs`.
  Bring the example up with `mise run up postgres-fdw`, then
  `mise run test postgres-fdw`.
  """

  use ExUnit.Case, async: false

  alias Topology.Api
  alias Topology.Eventually
  alias Topology.Example

  @moduletag :postgres_fdw
  @moduletag timeout: 600_000

  @example "postgres-fdw"
  @users 20
  @events 200
  @oltp_password "kind-only-oltp-password"

  setup_all do
    Example.require_up!(@example)

    api = Example.api(@example)
    Api.await_healthy!(api)

    dataset = Api.unique_name("fdw")
    Api.create_dataset!(api, dataset)
    create_events_table!(api, dataset, "events")
    Api.insert!(api, dataset, "events", events(1..@events))

    register_oltp!(api)

    {:ok, oltp} = oltp_connect()
    Postgrex.query!(oltp, "CREATE SCHEMA #{dataset}", [])
    import_foreign_table!(oltp, dataset, "events")

    %{api: api, dataset: dataset, oltp: oltp}
  end

  describe "from the Postgres side, over postgres_fdw" do
    test "IMPORT FOREIGN SCHEMA builds the foreign table with the right types", context do
      %{oltp: oltp, dataset: dataset} = context

      %Postgrex.Result{rows: rows} =
        Postgrex.query!(
          oltp,
          """
          SELECT column_name, data_type
            FROM information_schema.columns
           WHERE table_schema = $1 AND table_name = 'events'
           ORDER BY ordinal_position
          """,
          [dataset]
        )

      assert rows == [["id", "bigint"], ["user_id", "bigint"], ["amount", "numeric"]]
    end

    test "an aggregate over the foreign table is pushed down to smolquery", context do
      %{oltp: oltp, dataset: dataset} = context

      sql = "SELECT user_id, count(*) FROM #{dataset}.events GROUP BY user_id ORDER BY user_id"

      %Postgrex.Result{rows: rows} = Postgrex.query!(oltp, sql, [])
      assert rows == for(user <- 1..@users, do: [user, div(@events, @users)])

      %Postgrex.Result{rows: plan} = Postgrex.query!(oltp, "EXPLAIN VERBOSE " <> sql, [])
      plan = Enum.map_join(plan, "\n", &hd/1)

      assert plan =~ "Foreign Scan"
      assert plan =~ ~r/Remote SQL:.*count\(\*\)/
      assert plan =~ ~r/Remote SQL:.*GROUP BY/
    end

    test "a join between the OLTP users and the foreign events answers", context do
      %{oltp: oltp, dataset: dataset} = context

      %Postgrex.Result{rows: rows} =
        Postgrex.query!(
          oltp,
          """
          SELECT u.plan, count(*), sum(e.amount)
            FROM public.users u
            JOIN #{dataset}.events e ON e.user_id = u.id
           GROUP BY u.plan
           ORDER BY u.plan
          """,
          []
        )

      assert Enum.map(rows, fn [plan, n, total] -> {plan, n, Decimal.to_integer(total)} end) ==
               expected_per_plan()
    end

    test "a REPEATABLE READ block pins its read while rows keep landing", context do
      %{api: api, oltp: oltp, dataset: dataset} = context

      create_events_table!(api, dataset, "pinned")
      Api.insert!(api, dataset, "pinned", events(1..50))
      import_foreign_table!(oltp, dataset, "pinned")

      count = "SELECT count(*) FROM #{dataset}.pinned"

      {:ok, {before, during}} =
        Postgrex.transaction(oltp, fn conn ->
          Postgrex.query!(conn, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
          before = scalar!(conn, count)
          Api.insert!(api, dataset, "pinned", events(51..100))
          {before, scalar!(conn, count)}
        end)

      assert before == 50
      assert during == 50
      assert scalar!(oltp, count) == 100
    end
  end

  describe "from the smolquery side, over a registered connection" do
    test "the OLTP database is registered and reachable", %{api: api} do
      assert %{status: 200} = Api.get!(api, "/v1/connections/oltp")
      assert %{status: 200} = Api.post!(api, "/v1/connections/oltp/test", %{})
    end

    test "a federated join over oltp.public.users answers", %{api: api, dataset: dataset} do
      {:ok, rows} =
        Api.query(api, """
        SELECT u.plan, count(*) AS n, sum(e.amount) AS total
          FROM #{dataset}.events e
          JOIN oltp.public.users u ON u.id = e.user_id
         GROUP BY u.plan
         ORDER BY u.plan
        """)

      assert Enum.map(rows, fn row ->
               {row["plan"], to_int(row["n"]), to_int(row["total"])}
             end) == expected_per_plan()
    end

    test "the attachment is read-only: a write through it is refused", %{api: api, oltp: oltp} do
      assert {:error, status} = Api.query(api, "UPDATE oltp.public.users SET plan = 'pro'")
      assert status in 400..499

      assert scalar!(oltp, "SELECT count(*) FROM public.users WHERE plan = 'pro'") ==
               div(@users, 4)
    end
  end

  defp create_events_table!(api, dataset, table) do
    Api.create_table!(api, dataset, table, [
      %{"name" => "id", "type" => "INT64", "nullable" => false},
      %{"name" => "user_id", "type" => "INT64"},
      %{"name" => "amount", "type" => "NUMERIC(38,2)"}
    ])
  end

  defp events(range) do
    for i <- range, do: %{"id" => i, "user_id" => user_of(i), "amount" => "#{i}.00"}
  end

  defp user_of(event), do: rem(event - 1, @users) + 1

  defp plan_of(user) when rem(user, 4) == 0, do: "pro"
  defp plan_of(_user), do: "free"

  defp expected_per_plan do
    1..@events
    |> Enum.group_by(&plan_of(user_of(&1)))
    |> Enum.map(fn {plan, ids} -> {plan, length(ids), Enum.sum(ids)} end)
    |> Enum.sort()
  end

  defp register_oltp!(api) do
    %{status: status} =
      Api.post!(api, "/v1/connections", %{
        "name" => "oltp",
        "host" => "oltp-postgres",
        "port" => 5432,
        "database" => "app",
        "username" => "app",
        "password" => @oltp_password,
        "sslmode" => "disable"
      })

    if status in [200, 201], do: :ok, else: raise("registering oltp answered #{status}")
  end

  defp oltp_connect do
    Postgrex.start_link(
      hostname: "localhost",
      port: Example.host_port(@example, :oltp),
      username: "app",
      password: @oltp_password,
      database: "app",
      ssl: false
    )
  end

  defp import_foreign_table!(oltp, dataset, table) do
    import_sql =
      "IMPORT FOREIGN SCHEMA #{dataset} LIMIT TO (#{table}) FROM SERVER smol INTO #{dataset}"

    exists = "SELECT to_regclass('#{dataset}.#{table}') IS NOT NULL"

    Eventually.until!(
      fn ->
        Postgrex.query!(oltp, import_sql, [])
        scalar!(oltp, exists)
      end,
      30,
      1_000,
      "#{dataset}.#{table} was never imported from server smol"
    )
  end

  defp scalar!(conn, sql) do
    %Postgrex.Result{rows: [[value]]} = Postgrex.query!(conn, sql, [])
    value
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: value |> Decimal.new() |> Decimal.to_integer()
  defp to_int(value) when is_float(value), do: round(value)
end
