defmodule Topology.ExampleTest do
  use ExUnit.Case, async: true

  alias Topology.Example

  test "every example directory has a port block, and every port block an example" do
    examples = "examples" |> File.ls!() |> Enum.sort()

    assert examples == Enum.sort(Example.names())
  end

  test "host ports are unique across examples" do
    ports = for {_example, _service, port} <- all_ports(), do: port

    assert ports == Enum.uniq(ports)
  end

  test "kind/cluster.yaml maps every host port the suites use" do
    mapped =
      ~r/hostPort: (\d+)/
      |> Regex.scan(File.read!("kind/cluster.yaml"))
      |> Enum.map(fn [_line, port] -> String.to_integer(port) end)

    for {example, service, port} <- all_ports() do
      assert port in mapped,
             "host port #{port} (#{example} #{service}) is not in kind/cluster.yaml"
    end
  end

  defp all_ports do
    for example <- Example.names(),
        service <- Example.services(example),
        do: {example, service, Example.host_port(example, service)}
  end
end
