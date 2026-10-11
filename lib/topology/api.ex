defmodule Topology.Api do
  @moduledoc """
  smolquery's HTTP API from a suite: datasets, tables, NDJSON inserts and
  queries, against one example's host port.

  Inserts carry an `insertId` and retry on the statuses a client is meant to
  retry, so a retried batch lands once and a suite's row counts stay exact.
  Queries answer `{:ok, rows}` or `{:error, status}` rather than raising,
  because "did this fail cleanly?" is itself something a topology's suite
  asserts.
  """

  defstruct [:base_url, :api_key]

  @type t :: %__MODULE__{base_url: String.t(), api_key: String.t()}

  @retry_statuses [408, 425, 429, 500, 502, 503, 504]

  @doc "An API handle for `base_url`, authenticating with `api_key`."
  @spec new(String.t(), String.t()) :: t()
  def new(base_url, api_key), do: %__MODULE__{base_url: base_url, api_key: api_key}

  @doc "Waits for `/healthz` to answer 200."
  @spec await_healthy!(t(), pos_integer()) :: :ok
  def await_healthy!(%__MODULE__{} = api, attempts \\ 60) do
    Topology.Eventually.until!(
      fn -> match?({:ok, %{status: 200}}, Req.get(api.base_url <> "/healthz", retry: false)) end,
      attempts,
      2_000,
      "the API never became healthy at #{api.base_url}"
    )
  end

  @doc "Creates `dataset`."
  @spec create_dataset!(t(), String.t()) :: :ok
  def create_dataset!(api, dataset) do
    %{status: status} = post!(api, "/v1/datasets", %{"id" => dataset})
    expect!(status, [200, 201], "create dataset #{dataset}")
  end

  @doc "Creates `table` in `dataset` with `schema` (the API's column list)."
  @spec create_table!(t(), String.t(), String.t(), [map()]) :: :ok
  def create_table!(api, dataset, table, schema) do
    %{status: status} =
      post!(api, "/v1/datasets/#{dataset}/tables", %{"id" => table, "schema" => schema})

    expect!(status, [200, 201], "create table #{dataset}.#{table}")
  end

  @doc "`PATCH`es a table: clustering, retention, partitions."
  @spec patch_table!(t(), String.t(), String.t(), map()) :: :ok
  def patch_table!(api, dataset, table, body) do
    %{status: status} =
      request!(api, :patch, "/v1/datasets/#{dataset}/tables/#{table}", json: body)

    expect!(status, [200], "patch table #{dataset}.#{table}")
  end

  @doc """
  Inserts `rows` as NDJSON under a fresh `insertId`, retrying the statuses a
  client is meant to retry. Every row must land, or this raises.
  """
  @spec insert!(t(), String.t(), String.t(), [map()]) :: :ok
  def insert!(api, dataset, table, rows) do
    insert_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    insert_with_retry(api, dataset, table, rows, insert_id, 15)
  end

  @doc "Runs `sql` through `POST /v1/queries`, answering its rows or the failing status."
  @spec query(t(), String.t()) :: {:ok, [map()]} | {:error, pos_integer()}
  def query(api, sql) do
    case post!(api, "/v1/queries", %{"query" => sql}) do
      %{status: 200, body: %{"rows" => rows}} -> {:ok, rows}
      %{status: status} -> {:error, status}
    end
  end

  @doc "Runs `sql` and answers the first row's `column` as an integer."
  @spec count(t(), String.t(), String.t()) :: {:ok, integer()} | {:error, pos_integer()}
  def count(api, sql, column \\ "n") do
    with {:ok, [row | _rest]} <- query(api, sql) do
      {:ok, row |> Map.fetch!(column) |> to_integer()}
    end
  end

  @doc "A name no other run shares: the catalog and the PVCs outlive a redeploy."
  @spec unique_name(String.t()) :: String.t()
  def unique_name(prefix) do
    "#{prefix}_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
  end

  @doc "A `GET` with the API's bearer token."
  @spec get!(t(), String.t()) :: Req.Response.t()
  def get!(api, path), do: request!(api, :get, path, [])

  @doc "A JSON `POST` with the API's bearer token."
  @spec post!(t(), String.t(), map()) :: Req.Response.t()
  def post!(api, path, body), do: request!(api, :post, path, json: body)

  @doc "A `DELETE` with the API's bearer token."
  @spec delete!(t(), String.t()) :: Req.Response.t()
  def delete!(api, path), do: request!(api, :delete, path, [])

  @doc "The `authorization` header every request here sends."
  @spec auth_header(t()) :: {String.t(), String.t()}
  def auth_header(%__MODULE__{api_key: api_key}), do: {"authorization", "Bearer #{api_key}"}

  defp insert_with_retry(api, dataset, table, rows, insert_id, attempts) do
    body = Enum.map_join(rows, "\n", &JSON.encode!/1) <> "\n"
    expected = length(rows)

    path =
      "/v1/datasets/#{dataset}/tables/#{table}/insert?insertId=#{URI.encode_www_form(insert_id)}"

    case request!(api, :post, path,
           body: body,
           headers: [{"content-type", "application/x-ndjson"}]
         ) do
      %{status: 200, body: %{"insertedRows" => ^expected, "insertErrors" => []}} ->
        :ok

      %{status: status} when status in @retry_statuses and attempts > 1 ->
        Process.sleep(2_000)
        insert_with_retry(api, dataset, table, rows, insert_id, attempts - 1)

      %{status: status, body: response} ->
        raise "insert into #{dataset}.#{table} answered #{status}: #{inspect(response)}"
    end
  end

  defp request!(%__MODULE__{} = api, method, path, options) do
    headers = [auth_header(api) | Keyword.get(options, :headers, [])]

    Req.request!(
      [method: method, url: api.base_url <> path, retry: false, receive_timeout: 60_000]
      |> Keyword.merge(Keyword.delete(options, :headers))
      |> Keyword.put(:headers, headers)
    )
  end

  defp expect!(status, allowed, what) do
    if status in allowed, do: :ok, else: raise("#{what} answered #{status}")
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)
end
