defmodule Topology.Example do
  @moduledoc """
  What a suite knows about the example it tests: its namespace, the host
  ports `kind/cluster.yaml` maps for it, and the one API key every example
  uses.

  A suite starts with `require_up!/1`, which fails with the exact command to
  run when the example is not deployed. A missing example is a missing
  fixture, and saying so beats a pile of connection errors.
  """

  alias Topology.Api
  alias Topology.Kube

  @api_key "kind-only-api-key"
  @web_username "smolquery"
  @web_password "kind-only-web-password"

  # Host ports, matching kind/cluster.yaml's extraPortMappings and each
  # example's NodePort service. One block of host ports per example.
  @ports %{
    "single-node" => %{api: 9100, web: 9102, pg: 9105, clickhouse: 9123, victoriametrics: 9128},
    "split-compute" => %{api: 9200, query_api: 9201, web: 9202, pg: 9205},
    "federated-read-clusters" => %{api: 9300, reader_1_api: 9301, reader_2_api: 9302},
    "hyperdx" => %{api: 9400, clickhouse: 9423, hyperdx: 9408},
    "victoriametrics" => %{api: 9500, victoriametrics: 9528, grafana: 9530},
    "postgres-fdw" => %{api: 9600, pg: 9605, oltp: 9606}
  }

  @doc "The names of every example this repo has a port block for."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@ports)

  @doc "The namespace `example` deploys into: its own name."
  @spec namespace(String.t()) :: String.t()
  def namespace(example) when is_map_key(@ports, example), do: example

  @doc "The services `example` exposes on the host."
  @spec services(String.t()) :: [atom()]
  def services(example), do: @ports |> Map.fetch!(example) |> Map.keys()

  @doc "The host port `kind/cluster.yaml` maps for `example`'s `service`."
  @spec host_port(String.t(), atom()) :: pos_integer()
  def host_port(example, service), do: @ports |> Map.fetch!(example) |> Map.fetch!(service)

  @doc "The API key every example's kustomization sets."
  @spec api_key() :: String.t()
  def api_key, do: @api_key

  @doc "The web UI's basic-auth credential, as every example's kustomization sets it."
  @spec web_credential() :: {String.t(), String.t()}
  def web_credential, do: {@web_username, @web_password}

  @doc "An API handle on `example`'s `service` port (`:api` by default)."
  @spec api(String.t(), atom()) :: Api.t()
  def api(example, service \\ :api) do
    Api.new("http://localhost:#{host_port(example, service)}", @api_key)
  end

  @doc "Raises, naming the command to run, unless `example` is deployed."
  @spec require_up!(String.t()) :: :ok
  def require_up!(example) do
    cond do
      not Kube.available?() ->
        raise "kube context #{Kube.context()} not found: run `mise run kind-up` first"

      not Kube.namespace_up?(namespace(example)) ->
        raise "example #{example} is not deployed: run `mise run up #{example}` first"

      true ->
        :ok
    end
  end
end
