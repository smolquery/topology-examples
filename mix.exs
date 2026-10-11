defmodule TopologyExamples.MixProject do
  use Mix.Project

  def project do
    [
      app: :topology_examples,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: ["lib"],
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [ignore_modules: []]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:postgrex, "~> 0.21"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "format", "credo --strict", "test"],
      ci: ["compile --warnings-as-errors", "format --check-formatted", "credo --strict", "test"]
    ]
  end
end
