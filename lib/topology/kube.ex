defmodule Topology.Kube do
  @moduledoc """
  `kubectl`, pinned to the kind cluster this repo creates and to one example's
  namespace.

  Every command here carries `--context kind-topology-examples`, so a suite
  can never reach an ambient cluster, and `KUBECONFIG` is the repo-scoped
  file `scripts/kind-up.sh` writes when that file exists. The destructive
  moves (`kill!/2`, `restart!/2`) are the ones a topology's suite needs to
  show what the shape survives.
  """

  @context "kind-topology-examples"
  @container "smolquery"

  @doc "The kube context every command here is pinned to."
  @spec context() :: String.t()
  def context, do: @context

  @doc "Whether the kind cluster's context exists at all."
  @spec available?() :: boolean()
  def available? do
    case System.find_executable("kubectl") do
      nil ->
        false

      _kubectl ->
        {output, 0} = System.cmd("kubectl", ["config", "get-contexts", "-o", "name"], env: env())
        @context in String.split(output, "\n", trim: true)
    end
  end

  @doc "Whether `namespace` exists in the cluster."
  @spec namespace_up?(String.t()) :: boolean()
  def namespace_up?(namespace) do
    match?({_output, 0}, run(["get", "namespace", namespace]))
  end

  @doc "Runs `kubectl` in `namespace`."
  @spec kubectl(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def kubectl(namespace, args), do: run(["-n", namespace] ++ args)

  @doc "`kubectl/2`, raising on a non-zero exit and returning trimmed output."
  @spec kubectl!(String.t(), [String.t()]) :: String.t()
  def kubectl!(namespace, args) do
    case kubectl(namespace, args) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "kubectl #{Enum.join(args, " ")} exited #{status}:\n#{output}"
    end
  end

  @doc "Runs a command inside `pod`'s smolquery container."
  @spec exec!(String.t(), String.t(), [String.t()]) :: String.t()
  def exec!(namespace, pod, command) do
    kubectl!(namespace, ["exec", pod, "-c", @container, "--"] ++ command)
  end

  @doc "Evaluates `code` inside `pod`'s running release and returns its last line."
  @spec rpc!(String.t(), String.t(), String.t()) :: String.t()
  def rpc!(namespace, pod, code) do
    namespace
    |> exec!(pod, ["/app/bin/smolquery", "rpc", code])
    |> String.replace("\r", "")
    |> String.split("\n", trim: true)
    |> List.last("")
  end

  @doc "The names of the pods matching `selector`, without the `pod/` prefix."
  @spec pods(String.t(), String.t()) :: [String.t()]
  def pods(namespace, selector) do
    namespace
    |> kubectl!(["get", "pods", "-l", selector, "-o", "name"])
    |> String.split("\n", trim: true)
    |> Enum.map(&String.replace_prefix(&1, "pod/", ""))
  end

  @doc "Deletes `pod` without a grace period: a crash, not a shutdown."
  @spec kill!(String.t(), String.t()) :: :ok
  def kill!(namespace, pod) do
    kubectl!(namespace, ["delete", "pod", pod, "--force", "--grace-period=0", "--wait=false"])
    :ok
  end

  @doc "Deletes `pod` with its normal grace period; its controller replaces it."
  @spec restart!(String.t(), String.t()) :: :ok
  def restart!(namespace, pod) do
    kubectl!(namespace, ["delete", "pod", pod, "--wait=false"])
    :ok
  end

  @doc "Waits for `workload` (`statefulset/x` or `deployment/x`) to roll out."
  @spec rollout_status!(String.t(), String.t(), pos_integer()) :: :ok
  def rollout_status!(namespace, workload, timeout_s \\ 300) do
    kubectl!(namespace, ["rollout", "status", workload, "--timeout=#{timeout_s}s"])
    :ok
  end

  defp run(args) do
    System.cmd("kubectl", ["--context", @context] ++ args, env: env(), stderr_to_stdout: true)
  end

  defp env do
    kubeconfig = Path.join(File.cwd!(), ".kube/config")

    if File.exists?(kubeconfig), do: [{"KUBECONFIG", kubeconfig}], else: []
  end
end
