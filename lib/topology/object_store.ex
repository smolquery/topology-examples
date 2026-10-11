defmodule Topology.ObjectStore do
  @moduledoc """
  What a suite can see of the sealed tier's object store: the keys under a
  prefix, listed through the S3 API from inside the cluster.

  RustFS is reachable only inside the cluster, so the listing runs in a
  one-shot curl pod, signed with the store's static credentials. A suite
  that waits for a seal polls this; a key under `<dataset>/` is a sealed
  segment of that dataset, in the layout `Smolquery.Segments.Store.S3`
  writes.
  """

  alias Topology.Kube

  @image "curlimages/curl:8.22.0"
  @service "rustfs"
  @bucket "smolquery-sealed"
  @credentials "smolquery:smolquery-secret"

  @doc "The object keys under `prefix` in the sealed tier's bucket."
  @spec keys(String.t(), String.t()) :: [String.t()]
  def keys(namespace, prefix) do
    url = "http://#{@service}:9000/#{@bucket}?list-type=2&prefix=#{URI.encode(prefix)}"

    script =
      "curl -sS --fail --aws-sigv4 aws:amz:us-east-1:s3 --user #{@credentials} '#{url}'"

    ~r{<Key>([^<]+)</Key>}
    |> Regex.scan(run_once!(namespace, script))
    |> Enum.map(fn [_match, key] -> key end)
  end

  @doc "Whether any object of `dataset` has been sealed into the bucket."
  @spec sealed?(String.t(), String.t()) :: boolean()
  def sealed?(namespace, dataset), do: keys(namespace, dataset <> "/") != []

  defp run_once!(namespace, script) do
    name = "ls-#{System.unique_integer([:positive])}"

    Kube.kubectl!(namespace, [
      "run",
      name,
      "--rm",
      "-i",
      "--quiet",
      "--restart=Never",
      "--image=#{@image}",
      "--",
      "sh",
      "-c",
      script
    ])
  end
end
